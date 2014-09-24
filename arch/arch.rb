require 'metasm'

class Arch
  attr_reader :instructions

  def initialize(data)
    @data = data
    @instructions = []

    disassemble()
    do_refs()
  end

  # wordsize, in bits
  def wordsize()
    raise NotImplementedError
  end
  def mandatory_jump?(i)
    raise NotImplementedError
  end
  def optional_jump?(i)
    raise NotImplementedError
  end
  def jump?(i)
    return mandatory_jump?(i) || optional_jump?(i)
  end

  def do_refs()
    # Create an index of instructions by address
    # TODO: There are more efficient ways to do this
    i_by_address = {}
    @instructions.each do |i|
      i_by_address[i[:offset]] = i
    end

    # Deal with jumps / xrefs / etc (note: this isn't really architecture-specific)
    0.upto(@instructions.length - 1) do |i|
      instruction = @instructions[i]

      refs = []
      operator = instruction[:instruction][:operator]
      operand = instruction[:instruction][:operands][0]

      # If it's not a mandatory jump, it references the next address
      if(!mandatory_jump?(operator))
        if(!@instructions[i+1].nil?)
          refs << @instructions[i+1][:offset]
        end
      end

      # If it's a jump of any kind (with an immediate destination), fill in the ref
      if((jump?(operator)) && operand[:type] == 'immediate')
        refs << operand[:value]
      end

      # Do Xrefs for each of the refs we just found
      refs.each do |r|
        if(!i_by_address[r].nil?)
          i_by_address[r][:xrefs] << instruction[:offset]
        end
      end

      @instructions[i][:refs] = refs
    end
  end
end
