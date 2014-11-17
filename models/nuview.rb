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

class NuViewException < StandardError
end

class NuView < ActiveRecord::Base
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

  def initialize(params = {})
    super(params.merge({
      :deltas      => [],
      :undo_buffer => [],
      :redo_buffer => [],
      :segments    => {},
      :rev         => 0,
    }))

    init()
    @starting_revision = 0
  end

  def revision()
    self.rev += 1

    return self.rev
  end

  def create_segments(segments)
    # Force segments into an array
    if(!segments.is_a?(Array))
      segments = [segments]
    end

    segments.each do |segment|
      # Do some sanity checks
      if(segment[:name].nil?)
        raise(NuViewException, "The 'name' field is required when creating a segment")
      end
      if(!self.segments[segment[:name]].nil?)
        raise(NuViewException, "A segment with that name already exists!")
      end
      if(segment[:address].nil?)
        raise(NuViewException, "The 'address' field is required when creating a segment")
      end
      if(segment[:data].nil?)
        raise(NuViewException, "The 'data' field is required when creating a segment")
      end

      # Create the 'special' fields
      segment[:revision] = revision()
      segment[:nodes]    = {}
      segment[:xrefs]    = []

      # Store the new segment
      self.segments[name] = segment

      # Save the opposite into the undo buffer
      self.undo_buffer << {
        :type  => :delete_segments,
        :names => [name],
      }
    end
  end

  def delete_segments(names)
    # Force names into being an array
    if(!names.is_a?(Array))
      names = [names]
    end

    names.each do |name|
      segment = self.segments[name]
      if(segment.nil?)
        raise(NuViewException, "A segment with that name could not be found!")
      end

      # Make sure it doesn't have any nodes
      delete_nodes(name, ((segment[:addr])..(segment[:addr]+segment[:length]-1)).to_a())

      # Officially delete the segment
      self.segments.delete(name)

      # Save the opposite into the undo buffer
      self.undo_buffer << {
        :type => :create_segment,
        :segments => [segment]
      }
    end
  end

  def create_nodes(segment_name, nodes)
    # Find the segment
    segment = self.segments[segment_name]
    if(segment.nil?)
      raise(NuViewException, "A segment with that name could not be found!")
    end

    # Force nodes into being an array
    if(!nodes.is_a?(Array))
      nodes = [nodes]
    end

    # Loop through the nodes
    nodes.each do |node|
      # Sanity checks
      if(node[:type].nil?)
        raise(NuViewException, "The 'type' field is required!")
      end
      if(node[:address].nil?)
        raise(NuViewException, "The 'address' field is required!")
      end
      if(node[:length].nil?)
        raise(NuViewException, "The 'length' field is required!")
      end
      if(node[:value].nil?)
        raise(NuViewException, "The 'value' field is required!")
      end

      # Record/update the revisions
      node[:revision] = revision()
      segment[:revision] = revision()

      # Loop through all the addresses in the node
      ((node[:address])..(node[:address]+node[:length]-1)).each do |address|
        # Make sure the memory we're gonna use is undefined
        delete_nodes(segment_name, address)

        # Create the segment
        segment[:nodes][address] = node
      end

      # TODO: Record Xrefs

      # TODO: Sanity check the address

      # Save the opposite into the undo buffer
      self.undo_buffer << {
        :type    => :delete_node,
        :segment => segment_name,
        :nodes   => [node],
      }
    end
  end

  def delete_nodes(segment_name, addresses)
    segment = self.segments[segment_name]
    if(segment.nil?)
      raise(NuViewException, "A segment with that name could not be found!")
    end

    # TODO: Update 'revision' properly
    addresses.each do |address|
      if(!segment[:nodes][address].nil?)
        self.undo_buffer << {
          :type    => :create_nodes,
          :segment => :segment_name,
          :nodes   => segment[:nodes].delete(address)
        }
      end
    end
  end

  def each_address_in_segment(segment_name)
    segment = self.segments[segment_name]
    if(segment.nil?)
      raise(NuViewException, "A segment with that name could not be found!")
    end

    segment[:address].upto(segment[:address] + segment[:data].length() - 1) do |addr|
      yield(addr)
    end
  end

  def get_nodes_at(segment_name, addresses)
    segment = self.segments[segment_name]
    if(segment.nil?)
      raise(NuViewException, "A segment with that name could not be found!")
    end

    # Force addresses to be an array
    if(!addresses.is_a?(Array))
      addresses = [addresses]
    end

    nodes = {}
    addresses.each do |address|
      # Get the node
      node = segments[:nodes][node]

      if(!node.nil?)
        # Store it, possibly overwriting other instances of itself
        nodes[node[:address]] = node.merge({
          :raw => Base64.encode64(segment[:data][node[:address], node[:length]]),
        })
      else
        # Figure out a nice looking value
        value = segment[:data][addr].ord()
        if(value >= 0x20 && value < 0x7F)
          value = "<undefined> 0x%02x ; '%c'" % [value, value]
        else
          value = "<undefined> 0x%02x" % value
        end

        # Make a fake node
        nodes[node[:address]] = {
          :type    => "undefined",
          :address => addr,
          :length  => 1,
          :value   => value,
          :details => { },
          :raw     => Base64.encode64(segment[:data][address, 1]),
        }
      end
    end

    # And that's it!
    return nodes
  end

  def each_segment(names = nil, starting = nil)
    self.segments.each_pair do |name, segment|
      if(names.nil? || !names.index(name).nil?)
        # TODO: Revision numbers
        yield(segment)
      end
    end
  end

  def each_node(segment_names = nil, starting = nil)
    # I want to get changed nodes in ALL segments (not just changed segments), so this
    # method call needs to have starting=nil
    each_segment(segment_names, 0) do |segment|
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
      if(d[:type] == NuView::DELTA_CHECKPOINT)
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
        puts("** NO REDO:")
        puts()
        break
      end

      puts("REDO = #{d.inspect}")
      puts()

      # Add it to the undo buffer
      self.undo_buffer << d

      # Apply the delta
      do_delta_internal(d)
      self.deltas << d
      self.undo_buffer << d

      # If it's a checkpoint, break out
      if(d[:type] == NuView::DELTA_CHECKPOINT)
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
    when NuView::DELTA_CHECKPOINT
      # do nothing
      puts("DOING: checkpoint")
    when NuView::DELTA_CREATE_NODE
      puts("DOING: create_node(#{delta[:details]})")
      create_node(delta[:details])
    when NuView::DELTA_DELETE_NODE
      puts("DOING: delete_node(#{delta[:details]})")
      delete_node(delta[:details])
    when NuView::DELTA_CREATE_SEGMENT
      puts("DOING: create_segment(#{delta[:details]})")
      create_segment(delta[:details])
    when NuView::DELTA_DELETE_SEGMENT
      puts("DOING: delete_segment(#{delta[:details]})")
      delete_segment(delta[:details])
    else
      raise(NuViewException, "Unknown delta: #{delta}")
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
    return { :type => NuView::DELTA_CHECKPOINT }
  end

  def create_node_delta(node)
    return { :type => NuView::DELTA_CREATE_NODE, :details => node }
  end

  def delete_node_delta(address)
    overlay = get_overlay_at(address)
    if(overlay.nil?)
      raise(NuViewException, "Couldn't find any nodes at that address!")
    end

    node = overlay[:node]
    if(node.nil?)
      raise(NuViewException, "Couldn't find any nodes at that address!")
    end

    return { :type => NuView::DELTA_DELETE_NODE, :details => node }
  end

  def create_segment_delta(segment)
    return { :type => NuView::DELTA_CREATE_SEGMENT, :details => segment }
  end

  def delete_segment_delta(name)
    if(@segments[name].nil?)
      raise(VaultException, "Segment doesn't exist: \"#{name}\" (known segments: #{@segments.keys.map() { |s| "\"" + s + "\""}.join(", ")})")
    end

    segment = @segments[name][:segment]
    return { :type => NuView::DELTA_DELETE_SEGMENT, :details => segment }
  end

  def invert_delta(delta)
    case delta[:type]
    when NuView::DELTA_CHECKPOINT
      return create_checkpoint_delta()
    when NuView::DELTA_CREATE_NODE
      return delete_node_delta(delta[:details][:address])
    when NuView::DELTA_DELETE_NODE
      return create_node_delta(delta[:details])
    when NuView::DELTA_CREATE_SEGMENT
      return delete_segment_delta(delta[:details][:name])
    when NuView::DELTA_DELETE_SEGMENT
      return create_segment_delta(delta[:details])
    else
      raise(NuViewException, "Unknown delta type: #{delta[:type]}")
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
  m = NuView.new()

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

  other_m = NuView.find(id)

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
  #puts other_m.do_delta(NuView.create_segment_delta({ :name => "s1", :address => 0x1000, :file_address => 0x0000, :data => "\x5b\x5c\xca\xb9\x21\xa1\x65\x71\x53\x9a\x63\xd2\xd4\x5e\x7c\x55"}))

  loop do
    puts other_m.redo()
    puts()
    puts(other_m.to_s)
    $stdin.gets()
  end
end
