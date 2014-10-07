# memory.rb
# By Ron Bowes
# Created October 6, 2014

class MemoryNode
  attr_reader :type, :real_addr, :file_addr, :length

  def initialize(type, real_addr, file_addr, length)
    @type = type
    @real_addr = real_addr
    @file_addr = file_addr
    @length = length

    @xrefs = []
  end

  def raw(memory)
    return (memory[@real_addr, @length].map do |c| c.chr end).join
  end

  def value(memory)
    return "db 0x%02x" % (memory[@real_addr].ord & 0x0FF)
  end
end

class MemoryNodeDword < MemoryNode
  def initialize(real_addr, file_addr)
    super("dword", real_addr, file_addr, 4)
  end

  def value(memory)
    return "dd 0x%08x" % raw(memory).unpack("I")
  end
end

class MemoryNodeWord < MemoryNode
  def initialize(real_addr, file_addr)
    super("word", real_addr, file_addr, 2)
  end

  def value(memory)
    return "dw 0x%04x" % raw(memory).unpack("S")
  end
end

class MemoryNodeByte < MemoryNode
  def initialize(real_addr, file_addr)
    super("byte", real_addr, file_addr, 1)
  end

  def value(memory)
    return "db 0x%02x" % raw(memory)[0].ord
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

  def contains?(addr, len)
    return (addr >= @real_addr) && ((addr + len - 1) < (@real_addr + length()))
  end

  def contains_node?(node)
    return contains?(node.real_addr, node.length)
  end

  def each_address()
    @real_addr.upto(length() - 1) do |a|
      yield(address)
    end
  end

  def to_s()
    return "Segment: %s (0x%08x - 0x%08x)" % [@name, @real_addr, @real_addr + length()]
  end
end

class Memory
  class SegmentNotFoundException < StandardError
  end
  class SegmentationException < StandardError
  end
  class OverlappingSegmentException < StandardError
  end

  def initialize()
    @memory_bytes = []
    @memory_nodes = []
    @segments     = {}

    @actions = []
  end

  def find_segment(addr)
    @segments.each_pair do |_, s|
      if(addr >= s.real_addr && addr < (s.real_addr + s.length))
        return s
      end
    end

    raise SegmentationException
  end

  def remove_node(node, rewindable = true)
    node.real_addr.upto(node.real_addr + node.length - 1) do |addr|
      @memory_nodes[addr] = nil
    end

    if(rewindable)
      @actions << { :type => :remove, :node => node }
    end
  end

  def undefine(addr, len)
    addr.upto(addr + len - 1) do |a|
      if(!@memory_nodes[a].nil?)
        remove_node(@memory_nodes[a])
      end
    end
  end

  def add_node(node, rewindable = true)
    # Make sure we're in a valid segment
    segment = find_segment(node.real_addr)

    # Make sure there's enough room
    if(!segment.contains_node?(node))
      raise SegmentationException
    end

    # Make sure the nodes are undefined
    undefine(node.real_addr, node.length)

    # Reserve the memory
    node.real_addr.upto(node.real_addr + node.length - 1) do |addr|
      @memory_nodes[addr] = node
    end

    if(rewindable)
      @actions << { :type => :add, :node => node }
    end
  end

  def rewind(steps = 1)
    0.upto(steps - 1) do
      action = @actions.pop

      if(action[:type] == :add)
        remove_node(action[:node], false)
      elsif(action[:type] == :remove)
        add_node(action[:node], false)
      else
        puts("Unknown action: #{action[:type]}")
        raise NotImplementedException
      end
    end
  end

  def mount_segment(segment)
    # Make sure the memory isn't already in use
    memory = @memory_nodes[segment.real_addr, segment.length]
    if(!(memory.nil? || memory.compact().length() == 0))
      raise OverlappingSegmentException
    end

    # Keep track of the mount so we can unmount later
    @segments[segment.name] = segment

    # Insert the data
    @memory_bytes[segment.real_addr, segment.length] = segment.data
  end

  def unmount_segment(name)
    # Clear the memory for the segment
    segment = @segments['name']
    if(segment.nil?)
      raise SegmentNotFoundException
    end

    # Undefine its entire space
    undefine(segment.real_addr, segment.length - 1)

    # Delete the data
    @memory_bytes[segment.real_addr, segment.length] = [nil] * segment.length

    # Delete it
    @segments.delete(name)
  end

  def to_s()
    s = ""

    @segments.each do |segment|
      s += segment.to_s + "\n"
    end

    i = 0

    while(i < @memory_bytes.length) do
      # Check if there's a node defined
      if(@memory_nodes[i].nil? && @memory_bytes[i].nil?)
        # We're between segments, do nothing
        i += 1
      elsif(@memory_nodes[i].nil?)
        # We're not in a node, but we do have valid bytes/memory
        s += "0x%08x %02x <undefined>\n" % [i, @memory_bytes[i].ord]
        i += 1
      else
        # We're in a node
        s += "0x%08x %s\n" % [i, @memory_nodes[i].value(@memory_bytes)]
        i += @memory_nodes[i].length
      end
    end

    return s
  end

  def test()
    0.upto(@memory_nodes.length - 1) do |i|
      puts("%x => %s" % [i, @memory_nodes[i]])
    end
  end
end

m = Memory.new()

m.mount_segment(MemorySegment.new("s1", 0x1000, 0x0000, "A" * 16))
m.mount_segment(MemorySegment.new("s2", 0x2000, 0x0000, "B" * 8))

puts("Inserting new node")
m.add_node(MemoryNodeDword.new(0x1000, 0x0000))
m.add_node(MemoryNodeWord.new(0x1004, 0x0000))
m.add_node(MemoryNodeByte.new(0x1008, 0x0000))

puts(m.to_s)

m.add_node(MemoryNodeDword.new(0x1000, 0x0000))
m.add_node(MemoryNodeDword.new(0x1004, 0x0000))
m.add_node(MemoryNodeDword.new(0x1008, 0x0000))

puts(m.to_s)
puts()

while true do
  m.rewind(1)
  puts(m.to_s)
  gets()
end

