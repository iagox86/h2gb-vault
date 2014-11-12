# view.rb
# By Ron Bowes
# Created October 6, 2014

$LOAD_PATH << File.dirname(__FILE__)

require 'model.rb'

require 'json'
require 'sinatra/activerecord'

if(ARGV[0] == "testview")
  ActiveRecord::Base.establish_connection(
    :adapter => 'sqlite3',
    :host    => nil,
    :username => nil,
    :password => nil,
    :database => 'data.db',
    :encoding => 'utf8',
  )
end

class ViewException < StandardError
end

class View < ActiveRecord::Base
  include Model

  belongs_to(:workspace)

  serialize(:deltas)
  serialize(:undo_buffer)
  serialize(:redo_buffer)
  serialize(:snapshot)

  DELTA_CHECKPOINT     = 'checkpoint'
  DELTA_CREATE_SEGMENT = 'create_segment'
  DELTA_DELETE_SEGMENT = 'delete_segment'
  DELTA_CREATE_NODE    = 'create_node'
  DELTA_DELETE_NODE    = 'delete_node'

  attr_reader :starting_revision

  # NOTE: If adding any fields to these, the take_snapshot() function has to be
  # updated as well
  def init()
    if(self.snapshot)
      puts("We have a snapshot to load!")

      @segments         = self.snapshot[:segments]
      @memory           = self.snapshot[:memory]
      @overlay          = self.snapshot[:overlay]
    else
      @segments = {}
      @memory   = []
      @overlay  = []
    end
  end

  def initialize(params = {})
    params[:deltas]      ||= []
    params[:undo_buffer] ||= []
    params[:redo_buffer] ||= []

    super(params)

    init()
    @starting_revision = 0
  end

  def delete_node(node)
    # Remove the node from the overlay
    node[:address].upto(node[:address] + node[:length] - 1) do |addr|
      @overlay[addr][:node] = nil
      @overlay[addr][:revision] = revision()
    end

    # Go through its references, and remove xrefs as necessary
    if(!node[:refs].nil?)
      node[:refs].each do |ref|
        xrefs = @overlay[ref][:xrefs]
        # It shouldn't ever be nil, but...
        if(!xrefs.nil?)
          xrefs.delete(node[:address])
        end
      end
    end
  end

  def undefine(addr, len)
    addr.upto(addr + len - 1) do |a|
      if(!@overlay[a][:node].nil?)
        action = delete_node_delta(addr)
        do_delta_internal(action)
        self.deltas << action
        self.undo_buffer << action
      end

      # Mark this node as recently updated
      @overlay[a][:revision] = revision()
    end
  end

  def create_node(node)
    # Make sure there's enough room for the entire node
    node[:address].upto(node[:address] + node[:length] - 1) do |addr|
      # There's no memory
      if(@memory[addr].nil?)
        raise(ViewException, "Tried to create a node where no memory is mounted")
      end
    end

    # Make sure the nodes are undefined
    undefine(node[:address], node[:length])

    # Make sure the references are arrays
    if(!node[:refs].is_a?(Array))
      node[:refs] = [node[:refs]]
    end

    # Save the node to memory
    node[:address].upto(node[:address] + node[:length] - 1) do |addr|
      @overlay[addr][:node] = node
      @overlay[addr][:revision] = revision()
    end

    if(!node[:refs].nil?)
      node[:refs].each do |ref|
        # Record the cross reference
        @overlay[ref][:xrefs] ||= []
        @overlay[ref][:xrefs] << node[:address]
      end
    end
  end

  def each_address_in_segment(segment)
    segment[:segment][:address].upto(segment[:segment][:address] + segment[:segment][:data].length() - 1) do |addr|
      yield(addr)
    end
  end

  def create_segment(segment)
    if(!@segments[segment[:name]].nil?)
      raise(ViewException, "That segment name is already in use!")
    end
    # Make sure the memory isn't already in use
    memory = @memory[segment[:address], segment[:data].length()]
    if(!(memory.nil? || memory.compact().length() == 0))
      raise(ViewException, "Tried to mount overlapping segments!")
    end

    # Keep track of the segment
    @segments[segment[:name]] = {
      :segment => segment,
      :revision => revision(),
    }

    # Map the data into memory
    @memory[segment[:address], segment[:data].length()] = segment[:data].split(//)

    # Create some empty overlays
    each_address_in_segment(@segments[segment[:name]]) do |addr|
      @overlay[addr] = { :revision => revision() }
    end
  end

  def delete_segment(segment)
    # Undefine its entire space
    undefine(segment[:address], segment[:data].length() - 1)

    # Delete the data and the overlay
    @memory[segment[:address], segment[:data].length()] = [nil] * segment[:data].length()

    # Get rid of the overlays
    each_address_in_segment(@segments[segment[:name]]) do |addr|
      @overlay[addr] = nil
    end

    # Delete it from the segments table
    @segments.delete(segment[:name])
  end

  def get_overlay_at(addr)
    memory  = @memory[addr]
    overlay = @overlay[addr]

    # Make sure we aren't in a weird situation
    if(memory.nil? && !overlay.nil?)
      puts("Something bad is happening...")
      raise Exception
    end

    # If we aren't in a defined segment, return nil
    if(memory.nil?)
      return nil
    end

    # Start with the basic result
    result = overlay.clone

    # If we aren't somewhere with an actual node, make a fake one
    if(overlay[:node].nil?)
      value = @memory[addr].ord()
      if(value >= 0x20 && value < 0x7F)
        value = "<undefined> 0x%02x ; '%c'" % [value, value]
      else
        value = "<undefined> 0x%02x" % value
      end
      result[:node] = { :type => "undefined", :address => addr, :length => 1, :value => value, :details => { }}
    else
      result[:node] = overlay[:node].clone
    end

    # Add extra fields that we magically have
    result[:raw] = Base64.encode64(get_bytes_at(addr, result[:node][:length]))

    # And that's it!
    return result
  end

  def each_segment(starting = nil)
    @segments.each_value do |segment|
      if(starting.nil? || segment[:revision] >= starting)
        yield(segment)
      end
    end
  end

  def each_node(starting = nil)
    # I want to get changed nodes in ALL segments (not just changed segments), so this
    # method call needs to have starting=nil
    each_segment(nil) do |segment|
      addr = segment[:segment][:address]

      while(addr < segment[:segment][:address] + segment[:segment][:data].length()) do
        overlay = get_overlay_at(addr)
        if(overlay.nil?)
          puts("No overlay at #{addr}...")
        end

        if(starting.nil? || overlay[:revision] >= starting)
          yield(addr, overlay)
        end

        addr += overlay[:node][:length]
      end
    end
  end

  def revision()
    return self.deltas.length()
  end

  def segments(starting = nil)
    results = []
    each_segment(starting) do |segment|
      results << segment
    end

    return results
  end

  def nodes(starting = nil)
    result = []

    each_node(starting) do |addr, overlay|
      result << overlay
    end

    return result
  end

  def get_bytes_at(addr, length)
    return (@memory[addr, length].map do |c| c.chr end).join
  end

  def get_dword_at(addr)
    return get_bytes_at(addr, 4).unpack("I")
  end

  def get_word_at(addr)
    return get_bytes_at(addr, 2).unpack("S")
  end

  def get_byte_at(addr)
    return get_bytes_at(addr, 1).ord
  end

  def undo()
    # Loop till we get to the start or hit a checkpoint
    loop do
      # Get the next thing to undo
      d = self.undo_buffer.pop()

      # Check if we're at the start
      if(d.nil?)
        break
      end

      # Apply the inverse delta
      inverted = invert_delta(d)
      do_delta_internal(inverted)
      self.deltas << inverted
      self.redo_buffer << d

      # If it's a checkpoint, break out
      if(d[:type] == View::DELTA_CHECKPOINT)
        break
      end
    end
  end

  # Note: this is the exact same as undo(), except with the lists swapped and no inverting
  def redo()
    # Loop till we get to the start or hit a checkpoint
    loop do
      # Get the next thing to redo
      d = self.redo_buffer.pop()

      # Check if we're at the start
      if(d.nil?)
        break
      end

      # Add it to the undo buffer
      self.undo_buffer << d

      # Apply the delta
      do_delta_internal(d)
      self.deltas << d
      self.undo_buffer << d

      # If it's a checkpoint, break out
      if(d[:type] == View::DELTA_CHECKPOINT)
        break
      end
    end
  end

  def take_snapshot()
    self.snapshot = {
      :segments => @segments,
      :memory   => @memory,
      :overlay  => @overlay,
      :revision => revision(),
    }
  end

  def do_delta_internal(delta)
    # Handle arrays of deltas transparently
    if(delta.is_a?(Array))
      delta.each do |d|
        do_delta_internal(d)
      end

      return
    end

    case delta[:type]
    when View::DELTA_CHECKPOINT
      # do nothing
      puts("DOING: checkpoint")
    when View::DELTA_CREATE_NODE
      puts("DOING: create_node(#{delta[:details]})")
      create_node(delta[:details])
    when View::DELTA_DELETE_NODE
      puts("DOING: delete_node(#{delta[:details]})")
      delete_node(delta[:details])
    when View::DELTA_CREATE_SEGMENT
      puts("DOING: create_segment(#{delta[:details]})")
      create_segment(delta[:details])
    when View::DELTA_DELETE_SEGMENT
      puts("DOING: delete_segment(#{delta[:details]})")
      delete_segment(delta[:details])
    else
      raise(ViewException, "Unknown delta: #{delta}")
    end

    # Take a snapshot
    take_snapshot()
  end

  def do_delta(delta, starting = nil)
    # Discard any REDO state
    self.redo_buffer.clear

    # Record a checkpoint for 'undo' purposes
    self.undo_buffer << create_checkpoint_delta()

    # Do the delta
    do_delta_internal(delta)
    self.deltas << delta
    self.undo_buffer << delta
  end

  def create_checkpoint_delta()
    return { :type => View::DELTA_CHECKPOINT }
  end

  def create_node_delta(node)
    return { :type => View::DELTA_CREATE_NODE, :details => node }
  end

  def delete_node_delta(address)
    overlay = get_overlay_at(address)
    if(overlay.nil?)
      raise(ViewException, "Couldn't find any nodes at that address!")
    end

    node = overlay[:node]
    if(node.nil?)
      raise(ViewException, "Couldn't find any nodes at that address!")
    end

    return { :type => View::DELTA_DELETE_NODE, :details => node }
  end

  def create_segment_delta(segment)
    return { :type => View::DELTA_CREATE_SEGMENT, :details => segment }
  end

  def delete_segment_delta(name)
    if(@segments[name].nil?)
      raise(VaultException, "Segment doesn't exist: \"#{name}\" (known segments: #{@segments.keys.map() { |s| "\"" + s + "\""}.join(", ")})")
    end

    segment = @segments[name][:segment]
    return { :type => View::DELTA_DELETE_SEGMENT, :details => segment }
  end

  def invert_delta(delta)
    case delta[:type]
    when View::DELTA_CHECKPOINT
      return create_checkpoint_delta()
    when View::DELTA_CREATE_NODE
      return delete_node_delta(delta[:details][:address])
    when View::DELTA_DELETE_NODE
      return create_node_delta(delta[:details])
    when View::DELTA_CREATE_SEGMENT
      return delete_segment_delta(delta[:details][:name])
    when View::DELTA_DELETE_SEGMENT
      return create_segment_delta(delta[:details])
    else
      raise(ViewException, "Unknown delta type: #{delta[:type]}")
    end
  end

  def to_s(starting = nil)
    s = "Current revision: #{revision()} (showing revisions starting #{starting || 0}):\n"

    each_segment(starting) do |segment|
      s += segment.to_s + "\n"
    end

    each_node(starting) do |addr, overlay|
      s += "[%2d] 0x%08x %s %s" % [overlay[:revision], addr, Base64.decode64(overlay[:raw]).unpack("H*").pop, overlay[:node].to_s]

      refs = overlay[:node][:refs]
      if(!refs.nil? && refs.length > 0)
        s += " REFS: " + (refs.map do |ref| '0x%08x' % ref; end).join(', ')
      end

      if(!overlay[:xrefs].nil? && overlay[:xrefs].length > 0)
        s += " XREFS: " + (overlay[:xrefs].map do |ref| '0x%08x' % ref; end).join(', ')
      end
      s += "\n"
    end

    return s
  end

  def to_json(params = {})
    starting = (params[:starting] || 0).to_i()
    with_nodes = (params[:with_nodes] == "true")
    with_data  = (params[:with_data]  == "true")

    result = {
      :name     => self.name,
      :view_id  => self.id,
      :revision => self.revision(),
      :segments => [],
    }

    # Ensure the names argument is always an array
    if(params[:names] == '')
      params[:names] = nil
    elsif(params[:names] && params[:names].is_a?(String))
      params[:names] = [params[:names]]
    end

    # I want all segments, because it's possible that a node inside a segment matters
    # TODO: When I update a node, also update the segment's revision
    each_segment(nil) do |segment|
      # Start at the beginning of the segment
      addr = segment[:segment][:address]

      # If the user wanted a specific node 
      if(!params[:names].nil? && !params[:names].include?(segment[:segment][:name]))
        next
      end

      # The entry for this segment
      s = {
        :name     => segment[:segment][:name],
        :revision => segment[:revision]
      }

      # Don't include the data if the requester doesn't want it
      if(with_data == true)
        s[:data] = Base64.encode64(segment[:segment][:data])
      end

      # Let the user skip including nodes
      if(with_nodes == true)
        s[:nodes] = []

        # Loop through the entire segment
        while(addr < segment[:segment][:address] + segment[:segment][:data].length()) do
          # Get the overlay for this node
          overlay = get_overlay_at(addr)
          if(overlay.nil?)
            raise(VaultException, "No overlay was defined at 0x%08x.. that shouldn't happen!" % addr)
          end

          # Check if it's new enough to be included
          if(overlay[:revision] >= starting)
            n = overlay.merge(overlay[:node])
            n.delete(:node)

            s[:nodes] << n
          end

          addr += overlay[:node][:length]
        end
      end

      # Check if this segment should be included
      if((!s[:nodes].nil? && s[:nodes].length > 0) || s[:revision] >= starting)
        result[:segments] << s
      end
    end

    return result
  end

  after_find do |c|
    # Initialize the objects we need
    init()

    # Set up the starting revision
    @starting_revision = revision()
  end

  after_create do |c|
    # Initialize the objects we need
    init()
  end

end

if(ARGV[0] == "testview")
  m = View.new()

  r = m.revision()

  puts("A: creating s1")
  puts m.do_delta(m.create_segment_delta({ :name => "s1", :address => 0x1000, :file_address => 0x0000, :data => "\x5b\x5c\xca\xb9\x21\xa1\x65\x71\x53\x9a\x63\xd2\xd4\x5e\x7c\x55"}))
  #$stdin.gets()

  puts("A-0-1: creating a byte")
  puts m.do_delta(m.create_node_delta({ :type => 'byte',  :address => 0x1000, :length => 1, :value => "dd 0x41"}))
  puts("A-0-2: replacing with a dword")
  puts m.do_delta(m.create_node_delta({ :type => 'dword', :address => 0x1000, :length => 4, :value => "dd 0x41414141"}))
  puts("A-0-3: replacing with a byte")
  puts m.do_delta(m.create_node_delta({ :type => 'byte',  :address => 0x1000, :length => 1, :value => "dd 0x41"}))
  puts("A-0-4: replacing with a dword")
  puts m.do_delta(m.create_node_delta({ :type => 'dword', :address => 0x1000, :length => 4, :value => "dd 0x41414141"}))

  puts("Undo: replacing dword")
  puts(m.undo())
  puts("Undo: replacing byte")
  puts(m.undo())
  puts("Undo: replacing dword")
  puts(m.undo())
  puts("Undo: creating byte")
  puts(m.undo())
  puts("Undo: creating segment")
  puts(m.undo())

  puts()
  puts("This should be empty:")
  puts(m.to_s())

  $stdin.gets()

  puts("A-3: creating s3")
  puts m.do_delta(m.create_segment_delta({ :name => "s3", :address => 0x1000, :file_address => 0x0000, :data => "\x5b\x5c\xca\xb9\x21\xa1\x65\x71\x53\x9a\x63\xd2\xd4\x5e\x7c\x55"}))
  #$stdin.gets()

  puts("B: creating s2")
  puts m.do_delta(m.create_segment_delta({ :name => "s2", :address => 0x2000, :file_address => 0x1000, :data => "\x74\x5c\xe2\x8e\x2f\x3c\xd1\xea"}))
  puts m.to_s
  $stdin.gets()

  puts("B2: dropping s2")
  puts m.do_delta(m.delete_segment_delta("s2"))
  puts m.to_s
  $stdin.gets()


  puts("C: creating a plain ol' dword")
  puts m.do_delta(m.create_node_delta({ :type => 'dword', :address => 0x1000, :length => 4, :value => "dd 0x41414141", :details => { value: 0x41414141 }, :refs => [0x1004]}))
  #$stdin.gets()

  puts("D: creating another plain ol' dword")
  puts m.do_delta(m.create_node_delta({ :type => 'dword', :address => 0x1004, :length => 4, :value => "dd 0x41414141", :details => { value: 0x41414141 }, :refs => [0x1008]}))
  #$stdin.gets()

  puts("E: creating another plain ol' dword")
  puts m.do_delta(m.create_node_delta({ :type => 'dword', :address => 0x1008, :length => 4, :value => "dd 0x41414141", :details => { value: 0x41414141 }, :refs => [0x100c]}))
  #$stdin.gets()

  puts("F: Creating a dword that should undefine another dword")
  puts m.do_delta(m.create_node_delta({ :type => 'dword', :address => 0x1000, :length => 4, :value => "dd 0x42424242", :details => { value: 0x42424242 }, :refs => [0x1004]}))
  #$stdin.gets()

  puts("G: Creating a word that should undefine a dword")
  puts m.do_delta(m.create_node_delta({ :type => 'word' , :address => 0x1004, :length => 2, :value => "dw 0x4242",     :details => { value: 0x4242 }, :refs => [0x1008]}))
  #$stdin.gets()

  puts("G: Creating a byte that should undefine a dword")
  puts m.do_delta(m.create_node_delta({ :type => 'byte' , :address => 0x1008, :length => 1, :value => "db 0x42",       :details => { value: 0x42 } }))
  #$stdin.gets()

  puts()
  puts("Doing a save + load")

  m.save()
  id = m.id

  puts()
  puts("id = #{id}")
  puts()

  other_m = View.find(id)

  puts("Loaded from DB:")
  puts(other_m.to_s)
  puts()
  $stdin.gets()
  puts()

  while other_m.segments.length > 0 do
    puts other_m.undo()
    puts()
    puts(other_m.to_s)
    $stdin.gets()
  end

  # This will break the REDO chain
  #puts other_m.do_delta(View.create_segment_delta({ :name => "s1", :address => 0x1000, :file_address => 0x0000, :data => "\x5b\x5c\xca\xb9\x21\xa1\x65\x71\x53\x9a\x63\xd2\xd4\x5e\x7c\x55"}))

  loop do
    puts other_m.redo()
    puts()
    puts(other_m.to_s)
    $stdin.gets()
  end
end
