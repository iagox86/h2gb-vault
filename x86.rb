# x86.rb
# Created June, 2014
# By Ron Bowes

require 'metasm'

def disassemble_x86(code, bits = 32)
  cpu = nil
  instructions = []

  if(bits == 32)
    cpu = Metasm::X86.new
  elsif(bits == 64)
    cpu = Metasm::X86_64.new
  else
    raise(Exception, "Couldn't find a cpu that matches the bitsize")
  end

  d = Metasm::EncodedData.new(code)

  loop do
    start = d.ptr
    instruction = cpu.decode_instruction(d, start)

    if(instruction.nil?)
      break
    end

    bytes = code[start,instruction.bin_length]
    address = instruction.address
    instruction = instruction.instruction

    result = {
      :address => address,
      :bytes => Base64.encode64(bytes),
      :name => instruction.opname,
      :args => [],
    }

    instruction.args.each do |i|
      result[:args] << i.to_s()
    end

    instructions << result
  end

  return instructions
end
