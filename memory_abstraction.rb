# memory.rb
# By Ron Bowes
# Created October 6, 2014

require 'json'
require 'sinatra/activerecord'

ActiveRecord::Base.establish_connection(
  :adapter => 'sqlite3',
  :host    => nil,
  :username => nil,
  :password => nil,
  :database => 'data.db',
  :encoding => 'utf8',
)

class MemoryException < StandardError
end

class MemoryAbstraction < ActiveRecord::Base
  DELTA_CHECKPOINT     = 'checkpoint'
  DELTA_CREATE_SEGMENT = 'create_segment'
  DELTA_DELETE_SEGMENT = 'delete_segment'
  DELTA_CREATE_NODE    = 'create_node'
  DELTA_DELETE_NODE    = 'delete_node'

  serialize(:deltas)
  self.belongs_to(:workspace)

  def init_memory()
    # Segment info
    @segments = {}

    # The byte-by-byte memory
    @memory   = []

    # The metadata about memory
    @overlay  = []
  end

  def initialize(params = {})
    params[:deltas] ||= []
    params[:current_revision] ||= 0

    super(params)

    init_memory()
  end

  def remove_node(node)
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
        do_delta_internal(MemoryAbstraction.delete_node_delta(@overlay[a][:node]))
      end
    end
  end

  def add_node(node)
    # Make sure there's enough room for the entire node
    node[:address].upto(node[:address] + node[:length] - 1) do |addr|
      # There's no memory
      if(@memory[addr].nil?)
        raise(MemoryException, "Tried to create a node where no memory is mounted")
      end
    end

    # Make sure the nodes are undefined
    undefine(node[:address], node[:length])

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
    # Make sure the memory isn't already in use
    memory = @memory[segment[:address], segment[:data].length()]
    if(!(memory.nil? || memory.compact().length() == 0))
      raise(MemoryException, "Tried to mount overlapping segments!")
    end

    # Keep track of the segment
    @segments[segment[:name]] = {
      :segment => segment,
      :revision => revision(),
      :deleted => nil,
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
    each_address_in_segment(segment) do |addr|
      @overlay[addr] = nil
    end

    # Delete it from the segments table
    @segments[segment[:name]][:is_deleted] = revision()
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
        value = "0x%02x ; '%c'" % [value, value]
      else
        value = "0x%02x" % value
      end
      result[:node] = { :type => "undefined", :address => addr, :length => 1, :value => value, :details => { }}
    else
      result[:node] = overlay[:node].clone
    end

    # Add extra fields that we magically have
    result[:raw] = get_bytes_at(addr, result[:node][:length])

    # And that's it!
    return result
  end

  def each_segment(since = nil)
    since = nil

    @segments.each_value do |segment|
      if((since.nil? || segment[:revision] > since) && segment[:deleted].nil?)
        yield(segment)
      end
    end
  end

  def each_node(since = nil)
    # I want to get changed nodes in ALL segments (not just changed segments), so this
    # method call needs to have since=nil
    each_segment(nil) do |segment|
      addr = segment[:segment][:address]

      while(addr < segment[:segment][:address] + segment[:segment][:data].length()) do
        overlay = get_overlay_at(addr)

        if(since.nil? || overlay[:revision] > since)
          yield(addr, overlay)
        end

        addr += overlay[:node][:length]
      end
    end
  end

  def revision()
    return self.current_revision()
  end

  def segments(since)
    results = []
    each_segment(since) do |segment|
      results << segment
    end

    return results
  end

  def nodes(since = nil)
    result = []

    each_node(since) do |addr, overlay|
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
      index = self.current_revision

      # Break if we hit the start
      if(index < 0)
        break
      end

      # Get the delta at this index
      d = self.deltas[index]

      # Go to the previous revision
      self.current_revision -= 1

      # If it's a checkpoint, break out
      if(d[:type] == MemoryAbstraction::DELTA_CHECKPOINT)
        break
      end

      # Apply the inverse delta
      do_delta_internal(MemoryAbstraction.invert_delta(d), false)
    end

    # Return the nodes that changed between the current revision and the the head
    # TODO: If this actually works, I don't think it's the most efficient route
    return { :segments => segments(self.current_revision), :nodes => nodes(self.current_revision) }
  end

  def redo()
    # Keep track of where we started so we can return just what changed
    start_revision = self.current_revision

    # Loop till we get to the start or hit a checkpoint
    loop do
      index = self.current_revision

      # Get the next delta
      d = self.deltas[index + 1]

      # If we're at the end of the list, break
      if(d.nil?)
        break
      end

      # Increment the current revision
      self.current_revision += 1

      # If it's a checkpoint, break out
      if(d[:type] == MemoryAbstraction::DELTA_CHECKPOINT)
        break
      end

      # Re-apply the delta
      do_delta_internal(d, false)
    end

    # Return the nodes that changed between the current revision and the the head
    # TODO: Is this going to guarantee we get the right nodes? I feel like it does...
    return { :segments => segments(start_revision - 1), :nodes => nodes(start_revision - 1) }
  end

  def do_delta_internal(delta, rewindable = true)
    case delta[:type]
    when MemoryAbstraction::DELTA_CHECKPOINT
      # do nothing
    when MemoryAbstraction::DELTA_CREATE_NODE
      add_node(delta[:details])
    when MemoryAbstraction::DELTA_DELETE_NODE
      remove_node(delta[:details])
    when MemoryAbstraction::DELTA_CREATE_SEGMENT
      create_segment(delta[:details])
    when MemoryAbstraction::DELTA_DELETE_SEGMENT
      delete_segment(delta[:details])
    else
      raise(MemoryException, "Unknown delta: #{delta}")
    end

    # Record this action
    # Note: this has to be after the action, otherwise the undo history winds
    # up in the wrong order when actions recurse
    if(rewindable)
      # Add the new delta
      self.deltas << delta

      # Set the appropriate revision
      self.current_revision = self.deltas.length
    end
  end

  def do_delta(delta)
    # Discard REDO state if we have any
    if(self.current_revision != self.deltas.length())
      puts("(discarding REDO state, current state is #{self.current_revision} but we have a state of #{self.deltas.length()})")
      self.deltas = self.deltas[0, self.current_revision]
    end

    # Remember which revision we started on so we can send all the changed nodes
    start_revision = revision()

    # Record a checkpoint for 'undo' purposes
    self.deltas << MemoryAbstraction.create_checkpoint_delta()

    # Do the delta
    do_delta_internal(delta)

    # Return all the nodes since we started
    return { :segments => segments(start_revision), :nodes => nodes(start_revision) }
  end

  def MemoryAbstraction.create_checkpoint_delta()
    return { :type => MemoryAbstraction::DELTA_CHECKPOINT }
  end

  def MemoryAbstraction.create_node_delta(node)
    return { :type => MemoryAbstraction::DELTA_CREATE_NODE, :details => node }
  end

  def MemoryAbstraction.delete_node_delta(node)
    return { :type => MemoryAbstraction::DELTA_DELETE_NODE, :details => node }
  end

  def MemoryAbstraction.create_segment_delta(segment)
    return { :type => MemoryAbstraction::DELTA_CREATE_SEGMENT, :details => segment }
  end

  def MemoryAbstraction.delete_segment_delta(segment)
    return { :type => MemoryAbstraction::DELTA_DELETE_SEGMENT, :details => segment }
  end

  def MemoryAbstraction.invert_delta(delta)
    case delta[:type]
    when MemoryAbstraction::DELTA_CHECKPOINT
      return MemoryAbstraction.create_checkpoint_delta()
    when MemoryAbstraction::DELTA_CREATE_NODE
      return MemoryAbstraction.delete_node_delta(delta[:details])
    when MemoryAbstraction::DELTA_DELETE_NODE
      return MemoryAbstraction.create_node_delta(delta[:details])
    when MemoryAbstraction::DELTA_CREATE_SEGMENT
      return MemoryAbstraction.delete_segment_delta(delta[:details])
    when MemoryAbstraction::DELTA_DELETE_SEGMENT
      return MemoryAbstraction.create_segment_delta(delta[:details])
    else
      raise(MemoryException, "Unknown delta type: #{delta[:type]}")
    end
  end

  def to_s(since = nil)
    s = "Current revision: #{self.current_revision} (showing revisions since #{since || 0}):\n"

    each_segment(since) do |segment|
      s += segment.to_s + "\n"
    end

    each_node(since) do |addr, overlay|
      s += "0x%08x %s %s" % [addr, overlay[:raw].unpack("H*").pop, overlay[:node].to_s]

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

  after_find do |c|
    # Initialize the objects we need
    init_memory()

    # Replay all the deltas
    0.upto(self.current_revision - 1) do |i|
      d = self.deltas[i]
      do_delta_internal(d, false)
    end
  end

  after_create do |c|
    # Initialize the objects we need
    init_memory()
  end

end

if(ARGV[0] == "testmemory")
  m = MemoryAbstraction.new()

  r = m.revision()

  puts("A:")
  puts m.do_delta(MemoryAbstraction.create_segment_delta({ :name => "s1", :address => 0x1000, :file_address => 0x0000, :data => "\x5b\x5c\xca\xb9\x21\xa1\x65\x71\x53\x9a\x63\xd2\xd4\x5e\x7c\x55"}))
  #puts(m.to_s(r))
  #r = m.revision()
  #$stdin.gets()

  puts("B:")
  puts m.do_delta(MemoryAbstraction.create_segment_delta({ :name => "s2", :address => 0x2000, :file_address => 0x1000, :data => "\x74\x5c\xe2\x8e\x2f\x3c\xd1\xea"}))
  #puts(m.to_s(r))
  #r = m.revision()
  #$stdin.gets()
  exit

  m.do_delta(MemoryAbstraction.create_node_delta({ :type => 'dword', :address => 0x1000, :length => 4, :value => "dd 0x41414141", :details => { value: 0x41414141 }, :refs => [0x1004]}))
  puts(m.to_s(r))
  r = m.revision()
  $stdin.gets()

  m.do_delta(MemoryAbstraction.create_node_delta({ :type => 'dword', :address => 0x1004, :length => 4, :value => "dd 0x41414141", :details => { value: 0x41414141 }, :refs => [0x1008]}))
  puts(m.to_s(r))
  r = m.revision()
  $stdin.gets()

  m.do_delta(MemoryAbstraction.create_node_delta({ :type => 'dword', :address => 0x1008, :length => 4, :value => "dd 0x41414141", :details => { value: 0x41414141 }, :refs => [0x100c]}))
  puts(m.to_s(r))
  r = m.revision()
  $stdin.gets()

  m.do_delta(MemoryAbstraction.create_node_delta({ :type => 'dword', :address => 0x1000, :length => 4, :value => "dd 0x42424242", :details => { value: 0x42424242 }, :refs => [0x1004]}))
  puts(m.to_s(r))
  r = m.revision()
  $stdin.gets()

  m.do_delta(MemoryAbstraction.create_node_delta({ :type => 'word' , :address => 0x1004, :length => 2, :value => "dw 0x4242",     :details => { value: 0x4242 }, :refs => [0x1008]}))
  puts(m.to_s(r))
  r = m.revision()
  $stdin.gets()

  m.do_delta(MemoryAbstraction.create_node_delta({ :type => 'byte' , :address => 0x1008, :length => 1, :value => "db 0x42",       :details => { value: 0x42 } }))
  puts(m.to_s(r))
  r = m.revision()
  $stdin.gets()

  exit

  puts()

  m.save()
  id = m.id

  puts()
  puts("id = #{id}")
  puts()

  other_m = MemoryAbstraction.find(id)

  puts("Loaded from DB:")
  puts(other_m.to_s)
  $stdin.gets()

  while true do
    other_m.undo()
    puts(other_m.to_s)
    $stdin.gets()
  end
end
