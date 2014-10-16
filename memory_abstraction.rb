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

    super(params)

    init_memory()
  end

  def remove_node(node)
    # Remove the node from the overlay
    node[:address].upto(node[:address] + node[:length] - 1) do |addr|
      @overlay[addr][:node] = nil
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
    segment[:address].upto(segment[:address] + segment[:data].length() - 1) do |addr|
      yield(addr)
    end
  end

  def create_segment(segment)
    # Make sure the memory isn't already in use
    memory = @memory[segment[:address], segment[:data].length()]
    if(!(memory.nil? || memory.compact().length() == 0))
      raise(MemoryException, "Tried to mount overlapping segments!")
    end

    # Keep track of the mount so we can unmount later
    @segments[segment[:name]] = segment

    # Map the data into memory
    @memory[segment[:address], segment[:data].length()] = segment[:data].split(//)

    # Create some empty overlays
    each_address_in_segment(segment) do |addr|
      @overlay[addr] = { :address => addr }
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
    @segments.delete(segment[:name])

    # TODO: Compact/defrag memory
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
      result[:node] = { :type => "undefined", :address => addr, :length => 1, :details => { :value => "undefined" }}
    else
      result[:node] = overlay[:node].clone
    end

    # Add extra fields that we magically have
    result[:raw] = get_bytes_at(addr, result[:node][:length])

    # And that's it!
    return result
  end

  def each_segment()
    @segments.each do |segment|
      yield(segment)
    end
  end

  def each_node()
    i = 0

    while(i < @overlay.length) do
      overlay = get_overlay_at(i)

      # If there was no overlay, just move on
      if(overlay.nil?)
        i += 1
      else
        yield i, overlay
        i += overlay[:node][:length]
      end
    end
  end

  def nodes()
    result = {}

    each_node() do |addr, overlay|
      result[addr] = overlay
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
    loop do
      d = self.deltas.pop()

      if(d.nil?)
        break
      end

      if(d[:type] == MemoryAbstraction::DELTA_CHECKPOINT)
        break
      end

      do_delta_internal(MemoryAbstraction.invert_delta(d), false)
    end
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
      self.deltas << delta
    end
  end

  def do_delta(delta)
    # Record a checkpoint for 'undo' purposes
    self.deltas << MemoryAbstraction.create_checkpoint_delta()

    return do_delta_internal(delta)
  end

  def replay_deltas()
    self.deltas.each do |d|
      do_delta_internal(d, false)
    end
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

  def to_s()
    s = ""

    @segments.each do |segment|
      s += segment.to_s + "\n"
    end

    each_node do |addr, overlay|
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
    init_memory()
    replay_deltas()
  end

  after_create do |c|
    init_memory()
  end

end

if(ARGV[0] == "testmemory")
  m = MemoryAbstraction.new()

  m.do_delta(MemoryAbstraction.create_segment_delta({ :type => 'segment', :name => "s1", :address => 0x1000, :file_address => 0x0000, :data => "ABCDEFGHIJKLMNOP"}))
  m.do_delta(MemoryAbstraction.create_segment_delta({ :type => 'segment', :name => "s2", :address => 0x2000, :file_address => 0x1000, :data => "abcdefghijklmnop"}))

  puts(m.to_s)
  $stdin.gets()

  m.do_delta(MemoryAbstraction.create_node_delta({ :type => 'dword', :address => 0x1000, :length => 4, :details => { value: 0x41414141 }, :refs => [0x1004]}))
  m.do_delta(MemoryAbstraction.create_node_delta({ :type => 'dword', :address => 0x1004, :length => 4, :details => { value: 0x41414141 }, :refs => [0x1008]}))
  m.do_delta(MemoryAbstraction.create_node_delta({ :type => 'dword', :address => 0x1008, :length => 4, :details => { value: 0x41414141 }, :refs => [0x100c]}))

  puts(m.to_s)
  $stdin.gets()

  m.do_delta(MemoryAbstraction.create_node_delta({ :type => 'dword', :address => 0x1000, :length => 4, :details => { value: 0x42424242 }, :refs => [0x1004]}))
  m.do_delta(MemoryAbstraction.create_node_delta({ :type => 'word' , :address => 0x1004, :length => 2, :details => { value: 0x4242 } }))
  m.do_delta(MemoryAbstraction.create_node_delta({ :type => 'byte' , :address => 0x1008, :length => 1, :details => { value: 0x42 } }))

  puts(m.to_s)
  $stdin.gets()

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
