require 'metasm'
require 'arch/arch'

class Intel < Arch
  MANDATORY_JUMPS = [ "jmp" ]
  OPTIONAL_JUMPS = [ "jo", "jno", "js", "jns", "je", "jz", "jne", "jnz", "jb", "jnae", "jc", "jnb", "jae", "jnc", "jbe", "jna", "ja", "jnbe", "jl", "jnge", "jge", "jnl", "jle", "jng", "jg", "jnle", "jp", "jpe", "jnp", "jpo", "jcxz", "jecxz" ]

  def initialize(data, offset = 0)
    super(data, offset)
  end

  def mandatory_jump?(i)
    return !(MANDATORY_JUMPS.index(i).nil?)
  end

  def optional_jump?(i)
    return !(OPTIONAL_JUMPS.index(i).nil?)
  end

  def disassemble_intel(cpu)
    d = Metasm::EncodedData.new(@data)
    @instructions = []

    loop do
      start = d.ptr
      i = cpu.decode_instruction(d, start+@base)

      if(i.nil?)
        break
      end
      bytes = @data[start,i.bin_length]
      address = i.address
      instruction = i.instruction

      operands = []
      instruction.args.each do |arg|
        if(arg.is_a?(Metasm::Expression))
          operands << {
            :type => 'immediate',
            :value => ("%s%s%s" % [arg.lexpr || '', arg.op || '', arg.rexpr || '']).to_i()
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
        :offset => address + @base,
        :raw    => bytes.unpack("H*").pop.gsub(/(..)(?=.)/, '\1 '),
        :type   => "instruction",
        :instruction => instruction,
        :refs => [],
        :xrefs => [],
      }

      @instructions << result
    end
  end
end
