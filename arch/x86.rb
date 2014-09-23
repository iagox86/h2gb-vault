# x86.rb
# Created June, 2014
# By Ron Bowes

require 'metasm'

module X86
  MANDATORY_JUMPS = [ "jmp" ]
  OPTIONAL_JUMPS  = [ "jo", "jno", "js", "jns", "je", "jz", "jne", "jnz", "jb", "jnae", "jc", "jnb", "jae", "jnc", "jbe", "jna", "ja", "jnbe", "jl", "jnge", "jge", "jnl", "jle", "jng", "jg", "jnle", "jp", "jpe", "jnp", "jpo", "jcxz", "jecxz" ]

  def disassemble_x86(code, base = 0)
    cpu = Metasm::X86.new
    d = Metasm::EncodedData.new(code)
    instructions = []
    i_by_address = {}

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
        :offset => address,
        :raw    => bytes.unpack("H*").pop.gsub(/(..)(?=.)/, '\1 '),
        :type   => "instruction",
        :instruction => instruction,
        :refs => [],
        :xrefs => [],
      }

      instructions << result
      i_by_address[result[:offset]] = result
    end

    # Deal with jumps / xrefs / etc (note: this isn't really architecture-specific)
    0.upto(instructions.length - 1) do |i|
      instruction = instructions[i]

      refs = []
      operator = instruction[:instruction][:operator]
      operand = instruction[:instruction][:operands][0]

      # If it's not a mandatory jump, it references the next address
      if(MANDATORY_JUMPS.index(operator).nil?)
        if(!instructions[i+1].nil?)
          refs << instructions[i+1][:offset]
        end
      end

      # If it's a jump of any kind (with an immediate destination), fill in the ref
      if((MANDATORY_JUMPS.index(operator) || OPTIONAL_JUMPS.index(operator)) && operand[:type] == 'immediate')
        refs << operand[:value]
      end

      # Do Xrefs for each of the refs we just found
      refs.each do |r|
        if(!i_by_address[r].nil?)
          i_by_address[r][:xrefs] << instruction[:offset]
        end
      end

      instructions[i][:refs] = refs
    end

    return instructions
  end
end
