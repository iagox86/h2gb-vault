require 'metasm'
require 'arch/arch'

class Intel < Arch
  # Basically, these are instructions from which execution will never return
  MANDATORY_JUMPS = [ 'jmp' ]

  # Lines that don't carry on
  DOESNT_RETURN = [ 'ret', 'retn' ]

  # These are instructions that may or may not return
  OPTIONAL_JUMPS = [ 'jo', 'jno', 'js', 'jns', 'je', 'jz', 'jne', 'jnz', 'jb', 'jnae', 'jc', 'jnb', 'jae', 'jnc', 'jbe', 'jna', 'ja', 'jnbe', 'jl', 'jnge', 'jge', 'jnl', 'jle', 'jng', 'jg', 'jnle', 'jp', 'jpe', 'jnp', 'jpo', 'jcxz', 'jecxz' ]

  # Registers that affect the stack
  STACK_REGISTERS = [ 'esp', 'rsp' ]

  def get_stack_change(instruction)
    op = instruction[:operator]
    op1 = instruction[:operands][0]
    op2 = instruction[:operands][1]

    if(op == 'push')
      return -self.wordsize / 8
    end

    if(op == 'pop')
      return self.wordsize / 8
    end

    if(op == 'pusha')
      return -(((self.wordsize / 8) / 2) * 8)
    end

    if(op == 'popa')
      return (((self.wordsize / 8) / 2) * 8)
    end

    if(op == 'pushad')
      return -((self.wordsize / 8) * 8)
    end

    if(op == 'popad')
      return ((self.wordsize / 8) * 8)
    end

    if(!op1.nil? && op1[:type] == 'register' && STACK_REGISTERS.index(op1[:value]))
      if(!op2.nil? && op2[:type] == 'immediate')
        value = op2[:value]
        if(op == 'add')
          return value
        elsif(op == 'sub')
          return -value
        end
      end
    end

    return 0
  end

  def initialize(data)
    super(data)
  end

  def mandatory_jump?(i)
    return !(MANDATORY_JUMPS.index(i).nil?)
  end

  def optional_jump?(i)
    return !(OPTIONAL_JUMPS.index(i).nil?)
  end

  def doesnt_return?(i)
    return !(DOESNT_RETURN.index(i).nil?)
  end

  def disassemble_intel(cpu)
    d = Metasm::EncodedData.new(@data)
    @instructions = []

    loop do
      start = d.ptr
      i = cpu.decode_instruction(d, start)

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
            :value => arg.to_s,
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
        :stack => get_stack_change(instruction) || 0,
      }

      @instructions << result
    end
  end
end
