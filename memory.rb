# memory.rb
# By Ron Bowes
# Created October 6, 2014

require 'json'
#require 'sinatra/activerecord'

class MemoryException < StandardError
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
    node[:address].upto(node[:address] + node[:length] - 1) do |addr|
      @overlay[addr].node = nil
    end

    # Go through its references, and remove xrefs as necessary
    if(!node[:refs].nil?)
      node[:refs].each do |ref|
        xrefs = @overlay[ref].xrefs
        # It shouldn't ever be nil, but...
        if(!xrefs.nil?)
          xrefs.delete(node[:address])
        end
      end
    end
  end

  def undefine(addr, len)
    addr.upto(addr + len - 1) do |a|
      if(!@overlay[a].node.nil?)
        do_delta_internal(Memory.delete_node_delta(@overlay[a].node))
      end
    end
  end

  def add_node(node)
    # Make sure there's enough room for the entire node
    node[:address].upto(node[:address] + node[:length] - 1) do |addr|
      # There's no memory
puts("addr = 0x%x" % addr)
      if(@memory[addr].nil?)
        raise(MemoryException, "Tried to create a node where no memory is mounted")
      end
    end

    # Make sure the nodes are undefined
    undefine(node[:address], node[:length])

    # Save the node to memory
    node[:address].upto(node[:address] + node[:length] - 1) do |addr|
      @overlay[addr].node = node
    end

    if(!node[:refs].nil?)
      node[:refs].each do |ref|
        # Record the cross reference
        @overlay[ref].xrefs << node[:address]
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
      puts("X:: %x" % addr)
      @overlay[addr] = MemoryOverlay.new(addr, nil)
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
    if(overlay.node.nil?)
      result.node = { :type => "undefined", :address => addr, :length => 1, :details => { :value => "undefined" }}
    else
      result.node = overlay.node.clone
    end

    # Add extra fields that we magically have
    result.raw = get_bytes_at(addr, result.node[:length])

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
        i += overlay.node[:length]
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

      if(d[:type] == :checkpoint)
        break
      end

      do_delta_internal(Memory.invert_delta(d), false)
    end
  end

  def do_delta_internal(delta, rewindable = true)
    case delta[:type]
    when :create_node
      add_node(delta[:details])
    when :delete_node
      remove_node(delta[:details])
    when :create_segment
      create_segment(delta[:details])
    when :delete_segment
      delete_segment(delta[:details])
    else
      raise(MemoryException, "Unknown delta: #{delta}")
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
    @deltas << Memory.create_checkpoint_delta()

    return do_delta_internal(delta)
  end

  def Memory.create_checkpoint_delta()
    return { :type => :checkpoint }
  end

  def Memory.create_node_delta(node)
    return { :type => :create_node, :details => node }
  end

  def Memory.delete_node_delta(node)
    return { :type => :delete_node, :details => node }
  end

  def Memory.create_segment_delta(segment)
    return { :type => :create_segment, :details => segment }
  end

  def Memory.delete_segment_delta(segment)
    return { :type => :delete_segment, :details => segment }
  end

  def Memory.invert_delta(delta)
    if(delta[:type] == :checkpoint)
      return Memory.create_checkpoint_delta()
    elsif(delta[:type] == :create_node)
      return Memory.delete_node_delta(delta[:details])
    elsif(delta[:type] == :delete_node)
      return Memory.create_node_delta(delta[:details])
    elsif(delta[:type] == :create_segment)
      return Memory.delete_segment_delta(delta[:details])
    elsif(delta[:type] == :delete_segment)
      return Memory.create_segment_delta(delta[:details])
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
      s += "0x%08x %s %s" % [addr, overlay.raw.unpack("H*").pop, overlay.node.to_s]

      refs = overlay.node[:refs]
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

m.do_delta(Memory.create_segment_delta({ :type => 'segment', :name => "s1", :address => 0x1000, :file_address => 0x0000, :data => "ABCDEFGHIJKLMNOP"}))
m.do_delta(Memory.create_segment_delta({ :type => 'segment', :name => "s2", :address => 0x2000, :file_address => 0x1000, :data => "abcdefghijklmnop"}))

puts(m.to_s)

m.do_delta(Memory.create_node_delta({ :type => 'dword', :address => 0x1000, :length => 4, :details => { value: 0x41414141 }, :refs => [0x1004]}))
m.do_delta(Memory.create_node_delta({ :type => 'dword', :address => 0x1004, :length => 4, :details => { value: 0x41414141 }, :refs => [0x1008]}))
m.do_delta(Memory.create_node_delta({ :type => 'dword', :address => 0x1008, :length => 4, :details => { value: 0x41414141 }, :refs => [0x100c]}))

puts(m.to_s)
gets()

m.do_delta(Memory.create_node_delta({ :type => 'dword', :address => 0x1000, :length => 4, :details => { value: 0x42424242 }, :refs => [0x1004]}))
m.do_delta(Memory.create_node_delta({ :type => 'word' , :address => 0x1004, :length => 2, :details => { value: 0x4242 } }))
m.do_delta(Memory.create_node_delta({ :type => 'byte' , :address => 0x1008, :length => 1, :details => { value: 0x42 } }))

puts(m.to_s)
gets()

while true do
  m.undo()
  puts(m.to_s)
  gets()
end

