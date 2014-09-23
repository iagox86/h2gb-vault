# x86.rb
# Created June, 2014
# By Ron Bowes

require 'metasm'

module X86
  def disassemble_x86(code, base = 0)
    cpu = Metasm::X86.new
    d = Metasm::EncodedData.new(code)
    instructions = []

    loop do
      start = d.ptr
      i = cpu.decode_instruction(d, start+base)

      if(i.nil?)
        break
      end
      bytes = code[start,i.bin_length]
      address = i.address
      instruction = i.instruction

      operands = []
      instruction.args.each do |arg|
        if(arg.is_a?(Metasm::Expression))
          operands << {
            :type => 'immediate',
            :value => "%s%s%s" % [arg.lexpr || '', arg.op || '', arg.rexpr || '']
          }
        elsif(arg.is_a?(Metasm::Ia32::Reg))
          operands << {
            :type => 'register',
            :value => arg.symbolic,
            :regsize => arg.sz,
            :regnum => arg.val,
          }
        elsif(arg.is_a?(Metasm::Ia32::ModRM))
          operands << {
            :type => 'memory',
            :value => arg.symbolic.to_s(),

            :segment         => arg.seg,
            :memsize         => arg.sz,
            :base_register   => arg.i.to_s(),
            :multiplier      => arg.s || 1,
            :offset          => arg.b.to_s(),
            :immediate       => arg.imm.nil? ? 0 : arg.imm.rexpr,
          }
        elsif(arg.is_a?(Metasm::Ia32::SegReg))
          operands << {
            :type => 'register',
            :value => arg.to_s()
          }
        else
          puts("Unknown argument type:")
          puts(arg.class)
          puts(arg)

          raise(NotImplementedError)
        end
      end

      instruction = {
          :operator => instruction.opname,
          :operands => operands,
      }

      result = {
        :offset => address,
        :raw    => bytes.unpack("H*").pop.gsub(/(..)(?=.)/, '\1 '),
        :type   => "instruction",
        :instruction => instruction,
        :refs   => [],
        :xrefs  => [],
      }

      instructions << result
    end

    return instructions
  end
end
