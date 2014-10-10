# memory.rb
# By Ron Bowes
# Created October 6, 2014

require 'json'

class Memory
  class SegmentationException < StandardError
  end

  class MemoryNode
    attr_reader :type, :address, :length, :details, :refs

    def initialize(type, address, length, details, refs = [])
      @type = type
      @address = address
      @length = length
      @details = details
      @refs = refs
    end

    def to_s()
      return "%s %s" % [@type, @details]
    end

    def to_json()
      # TODO
    end
  end

  class MemoryOverlay
    attr_accessor :address, :node, :raw, :xrefs

    def initialize(address, node = nil, raw = nil, xrefs = nil)
      @address = address
      @node = node
      @raw = raw || ""
      @xrefs = xrefs || []
    end
  end

  class MemorySegment
    attr_reader :name, :real_addr, :file_addr, :data

    def initialize(name, real_addr, file_addr, data)
      @name      = name
      @real_addr = real_addr
      @file_addr = file_addr
      @data      = data.split(//)
    end

    def length
      return @data.length
    end

    def to_s()
      return "Segment: %s (0x%08x - 0x%08x)" % [@name, @real_addr, @real_addr + length()]
    end

    def to_json()

    end

    def each_addr()
      @real_addr.upto(@real_addr + length() - 1) do |addr|
        yield(addr)
      end
    end
  end

  def initialize()
    # The byte-by-byte memory
    @memory   = []

    # The metadata about memory
    @overlay  = []

    # Segment info
    @segments = {}

    # Undo info
    @actions  = []
    @action_index = 0
  end

  def add_action(type, details)
    action = {
      :type => type,
      :details => details
    }

    @actions[@action_index] = action
    @action_index += 1

    if(!@actions[@action_index].nil?)
      @actions = @actions[0, @action_index - 1]
    end
  end

  def remove_node(node, rewindable = true)
    # Remove the node from the overlay
    node.address.upto(node.address + node.length - 1) do |addr|
      @overlay[addr].node = nil
    end

    # Go through its references, and remove xrefs as necessary
    node.refs.each do |ref|
      xrefs = @overlay[ref].xrefs
      # It shouldn't ever be nil, but...
      if(!xrefs.nil?)
        xrefs.delete(node.address)
      end
    end

    if(rewindable)
      add_action(:remove_node, node)
    end
  end

  def undefine(addr, len)
    addr.upto(addr + len - 1) do |a|
      if(!@overlay[a].node.nil?)
        remove_node(@overlay[a].node)
      end
    end
  end

  def add_node_internal(node, rewindable = true)
    # Make sure there's enough room for the entire node
    node.address.upto(node.address + node.length - 1) do |addr|
      # There's no memory
      if(@memory[addr].nil?)
        raise SegmentationException
      end
    end

    # Make sure the nodes are undefined
    undefine(node.address, node.length)

    # Save the node to memory
    node.address.upto(node.address + node.length - 1) do |addr|
      @overlay[addr].node = node
    end

    node.refs.each do |ref|
      # Record the cross reference
      @overlay[ref].xrefs << node.address
    end

    if(rewindable)
      add_action(:add_node, node)
    end
  end

  def add_node(type, address, length, details, refs = [], rewindable = true)
    node = MemoryNode.new(type, address, length, details, refs)

    return add_node_internal(node, rewindable)
  end

  def create_segment_internal(segment, rewindable = true)
    # Make sure the memory isn't already in use
    memory = @memory[segment.real_addr, segment.length]
    if(!(memory.nil? || memory.compact().length() == 0))
      raise(SegmentationException, "Tried to mount overlapping segments!")
    end

    # Keep track of the mount so we can unmount later
    @segments[segment.name] = segment

    # Map the data into memory
    @memory[segment.real_addr, segment.length] = segment.data

    # Create some empty overlays
    segment.each_addr do |addr|
      @overlay[addr] = MemoryOverlay.new(addr, nil)
    end

    if(rewindable)
      add_action(:create_segment, segment)
    end
  end

  def create_segment(name, real_addr, file_addr, data, rewindable = true)
    create_segment_internal(MemorySegment.new(name, real_addr, file_addr, data))
  end

  def delete_segment(name, rewindable = true)
    # Clear the memory for the segment
    segment = @segments[name]
    if(segment.nil?)
      raise(SegmentationException, "Tried to unmount a segment that doesn't seem to be mounted")
    end

    # Undefine its entire space
    undefine(segment.real_addr, segment.length - 1)

    # Delete the data and the overlay
    @memory[segment.real_addr, segment.length] = [nil] * segment.length

    # Get rid of the overlays
    # TODO: Use a segment.each_addr() thing
    segment.each_addr do |addr|
      @overlay[addr] = nil
    end

    # Delete it from the segments table
    @segments.delete(name)

    if(rewindable)
      add_action(:delete_segment, segment)
    end
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
    if(overlay.node.nil?)
      result.node = MemoryNode.new("undefined", addr, 1, { :value => "undefined" })
    else
      result.node = overlay.node.clone
    end

    # Add extra fields that we magically have
    result.raw = get_bytes_at(addr, result.node.length)

    # And that's it!
    return result
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
        i += overlay.node.length
      end
    end
  end

  def to_s()
    s = ""

    @segments.each do |segment|
      s += segment.to_s + "\n"
    end

    each_node do |addr, overlay|
      s += "0x%08x %s %s" % [addr, overlay.raw.unpack("H*").pop, overlay.node.to_s]

      refs = overlay.node.refs
      if(!refs.nil? && refs.length > 0)
        s += " REFS: " + (refs.map do |ref| '0x%08x' % ref; end).join(', ')
      end

      if(overlay.xrefs.length > 0)
        s += " XREFS: " + (overlay.xrefs.map do |ref| '0x%08x' % ref; end).join(', ')
      end
      s += "\n"
    end

    return s
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

  def rewind(steps = 1)
    0.upto(steps - 1) do
      action = @actions.pop

      if(action[:type] == :add_node)
        remove_node(action[:details], false)
      elsif(action[:type] == :remove_node)
        add_node_internal(action[:details], false)
      elsif(action[:type] == :delete_segment)
        create_segment_internal(action[:details], false)
      elsif(action[:type] == :create_segment)
        delete_segment(action[:details].name, false)
      else
        puts("Unknown action: #{action[:type]}")
        raise NotImplementedException
      end
    end
  end

end

m = Memory.new()

m.create_segment("s1", 0x1000, 0x0000, "ABCDEFGHIJKLMNOP")
m.create_segment("s2", 0x2000, 0x0000, "abcdefghijklmnop")

m.add_node('dword', 0x1000, 4, { value: m.get_dword_at(0x1000) }, [0x1004])
m.add_node('word',  0x1004, 2, { value: m.get_word_at(0x1004) }, [0x1008])
m.add_node('byte', 0x1008, 1, { value: m.get_byte_at(0x1008) }, [0x1000])

puts(m.to_s)
gets()

m.add_node('dword', 0x1000, 4, { value: m.get_dword_at(0x1000) }, [0x2000])
m.add_node('word',  0x1004, 4, { value: m.get_dword_at(0x1004) }, [0x2004])
m.add_node('byte',  0x1008, 4, { value: m.get_dword_at(0x1008) }, [0x2008])

puts(m.to_s)
gets()

while true do
  gets()
  m.rewind(1)
  puts(m.to_s)
end

