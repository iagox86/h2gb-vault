# memory.rb
# By Ron Bowes
# Created October 6, 2014

require 'json'
require 'sinatra/activerecord'

class SegmentationException < StandardError
end

class MemoryDelta#< ActiveRecord::Base
  attr_reader :type, :details

  private
  def initialize(type, details = nil)
    @type    = type
    @details = details
  end

  public
  def MemoryDelta.create_checkpoint()
    return MemoryDelta.new(:checkpoint)
  end

  def MemoryDelta.create_node(node)
    return MemoryDelta.new(:create_node, node)
  end

  def MemoryDelta.delete_node(node)
    return MemoryDelta.new(:delete_node, node)
  end

  def MemoryDelta.create_segment(segment)
    return MemoryDelta.new(:create_segment, segment)
  end

  def MemoryDelta.delete_segment(segment)
    return MemoryDelta.new(:delete_segment, segment)
  end

  def invert()
    if(@type == :checkpoint)
      return MemoryDelta.create_checkpoint()
    elsif(@type == :create_node)
      return MemoryDelta.delete_node(@details)
    elsif(@type == :delete_node)
      return MemoryDelta.create_node(@details)
    elsif(@type == :create_segment)
      return MemoryDelta.delete_segment(@details)
    elsif(@type == :delete_segment)
      return MemoryDelta.create_segment(@details)
    else
      raise(SegmentationException, "Unknown action: #{@type}")
    end
  end

  def to_s()
    if(@type == :checkpoint)
      return '--'
    else
      return "%s %s" % [@type, @details.to_s]
    end
  end
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
    return "0x%08x %s 0x%08x" % [@address, @type, @details[:value] == "undefined" ? 0 : @details[:value]]
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

  def each_addr()
    @real_addr.upto(@real_addr + length() - 1) do |addr|
      yield(addr)
    end
  end
end

class Memory
  def initialize()
    # Segment info
    @segments = {}

    # The byte-by-byte memory
    @memory   = []

    # The metadata about memory
    @overlay  = []

    # Real undo stuff
    @deltas = []
  end

  def remove_node(node)
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
  end

  def undefine(addr, len)
    addr.upto(addr + len - 1) do |a|
      if(!@overlay[a].node.nil?)
        do_delta_internal(MemoryDelta.delete_node(@overlay[a].node))
      end
    end
  end

  def add_node(node)
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
  end

  def create_segment(segment)
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
  end

  def delete_segment(segment)
    # Undefine its entire space
    undefine(segment.real_addr, segment.length - 1)

    # Delete the data and the overlay
    @memory[segment.real_addr, segment.length] = [nil] * segment.length

    # Get rid of the overlays
    segment.each_addr do |addr|
      @overlay[addr] = nil
    end

    # Delete it from the segments table
    @segments.delete(segment.name)
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
      d = @deltas.pop()

      if(d.nil?)
        break
      end

      if(d.type == :checkpoint)
        break
      end

      do_delta_internal(d.invert, false)
    end
  end

  def do_delta_internal(delta, rewindable = true)
    case delta.type
    when :create_node
      add_node(delta.details)
    when :delete_node
      remove_node(delta.details)
    when :create_segment
      create_segment(delta.details)
    when :delete_segment
      delete_segment(delta.details)
    else
      raise(SegmentationException, "Unknown delta: #{delta}")
    end

    # Record this action
    # Note: this has to be after the action, otherwise the undo history winds
    # up in the wrong order when actions recurse
    if(rewindable)
      @deltas << delta
    end
  end

  def do_delta(delta)
    # Record a checkpoint for 'undo' purposes
    @deltas << MemoryDelta.create_checkpoint()

    return do_delta_internal(delta)
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
end

m = Memory.new()

m.do_delta(MemoryDelta.create_segment(MemorySegment.new("s1", 0x1000, 0x0000, "ABCDEFGHIJKLMNOP")))
m.do_delta(MemoryDelta.create_segment(MemorySegment.new("s2", 0x2000, 0x0000, "abcdefghijklmnop")))

m.do_delta(MemoryDelta.create_node(MemoryNode.new('dword', 0x1000, 4, { value: 0x41414141 }, [0x1004])))
m.do_delta(MemoryDelta.create_node(MemoryNode.new('dword', 0x1004, 4, { value: 0x41414141 }, [0x1008])))
m.do_delta(MemoryDelta.create_node(MemoryNode.new('dword', 0x1008, 4, { value: 0x41414141 }, [0x100c])))

puts(m.to_s)
gets()

m.do_delta(MemoryDelta.create_node(MemoryNode.new('dword', 0x1000, 4, { value: 0x42424242 }, [0x1004])))
m.do_delta(MemoryDelta.create_node(MemoryNode.new('word',  0x1004, 2, { value: 0x4242 }, [0x1008])))
m.do_delta(MemoryDelta.create_node(MemoryNode.new('byte',  0x1008, 1, { value: 0x42 }, [0x100c])))

puts(m.to_s)
gets()

while true do
  m.undo()
  puts(m.to_s)
  gets()
end

