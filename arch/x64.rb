# x86.rb
# Created June, 2014
# By Ron Bowes

require 'metasm'

module X64
  def disassemble_x64(code, bits = 32)
    cpu = nil
    instructions = []

    cpu = Metasm::X86_64.new
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
end
