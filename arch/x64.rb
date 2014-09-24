# x64.rb
# Created June, 2014
# By Ron Bowes

require 'metasm'
require 'arch/intel'

class X64 < Intel
  MANDATORY_JUMPS = [ "jmp" ]
  OPTIONAL_JUMPS = [ "jo", "jno", "js", "jns", "je", "jz", "jne", "jnz", "jb", "jnae", "jc", "jnb", "jae", "jnc", "jbe", "jna", "ja", "jnbe", "jl", "jnge", "jge", "jnl", "jle", "jng", "jg", "jnle", "jp", "jpe", "jnp", "jpo", "jcxz", "jecxz" ]

  def initialize(data)
    super(data)
  end

  def wordsize()
    return 64
  end

  def disassemble()
    disassemble_intel(Metasm::X86_64.new)
  end
end
