# memory.rb
# By Ron Bowes
# Created October 6, 2014

class MemoryNode
  attr_reader :type, :segment, :real_addr, :file_addr, :length, :details

  def initialize(type, segment, real_addr, file_addr, length, details)
    @type = type
    @segment = segment
    @real_addr = real_addr
    @file_addr = file_addr
    @length = length
    @details = details

    @xrefs = []
  end

  def to_s()
    return @details.to_s()
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
  end

  def find_segment(addr)
    @segments.each_pair do |_, s|
      if(addr >= s.real_addr && addr < (s.real_addr + s.length))
        return s
      end
    end

    raise SegmentationException
  end

  def delete_node(node)
    node.real_addr.upto(node.real_addr + node.length - 1) do |addr|
      @memory_nodes[addr] = nil
    end
  end

  def undefine(addr, len)
    addr.upto(addr + len - 1) do |a|
      if(!@memory_nodes[a].nil?)
        delete_node(@memory_nodes[a])
      end
    end
  end

  def insert_node(node)
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
        s += "0x%08x %s\n" % [i, @memory_nodes[i].to_s]
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

m.insert_node(MemoryNode.new("dword", "s1", 0x1004, 0x0000, 4, { :value => '0x42424242' }))
m.insert_node(MemoryNode.new("dword", "s1", 0x100c, 0x0000, 4, { :value => '0x44444444' }))

puts(m.to_s)

puts("Inserting new node")
m.insert_node(MemoryNode.new("dword", "s1", 0x1000, 0x0000, 1, { :value => "0x41" }))
m.insert_node(MemoryNode.new("dword", "s1", 0x1001, 0x0000, 1, { :value => "0x41" }))
m.insert_node(MemoryNode.new("dword", "s1", 0x1002, 0x0000, 1, { :value => "0x41" }))
m.insert_node(MemoryNode.new("dword", "s1", 0x1003, 0x0000, 1, { :value => "0x41" }))
m.insert_node(MemoryNode.new("dword", "s1", 0x1008, 0x0000, 1, { :value => "0x41" }))
m.insert_node(MemoryNode.new("dword", "s1", 0x1009, 0x0000, 1, { :value => "0x41" }))
m.insert_node(MemoryNode.new("dword", "s1", 0x100a, 0x0000, 1, { :value => "0x41" }))
m.insert_node(MemoryNode.new("dword", "s1", 0x100b, 0x0000, 1, { :value => "0x41" }))
m.insert_node(MemoryNode.new("dword", "s1", 0x2001, 0x0000, 1, { :value => "0x44" }))

puts(m.to_s)
