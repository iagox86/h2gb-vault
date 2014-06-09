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
    instruction = cpu.decode_instruction(d, d.ptr)
    if(instruction.nil?)
      break
    end

    address = instruction.address
    instruction = instruction.instruction

    result = {
      :address => address,
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

#code = "" +
#  "\xFE\xC0" +                      # inc al
#  "\xFE\xC3" +                      # inc bl
#  "\x66\x40" +                      # inc ax
#  "\x66\x43" +                      # inc bx
#  "\x40" +                          # inc eax
#  "\x43" +                          # inc ebx
#  "\xEB\x00" +                      # jmp short 0xc
#  "\xEB\xFC" +                      # jmp short 0xa
#
#  "\xB0\x01" +                      # mov al,0x1
#  "\xB3\x01" +                      # mov bl,0x1
#
#  "\x66\xB8\x01\x00" +              # mov ax,0x1
#  "\x66\xBB\x01\x00" +              # mov bx,0x1
#
#  "\xB8\x01\x00\x00\x00" +          # mov eax,0x1
#  "\xB8\x02\x00\x00\x00" +          # mov eax,0x2
#
#  "\x04\x01" +                      # add al,0x1
#  "\x80\xC3\x01" +                  # add bl,0x1
#
#  "\x66\x83\xC0\x01" +              # add ax,byte +0x1
#  "\x66\x83\xC3\x01" +              # add bx,byte +0x1
#
#  "\x83\xC0\x01" +                  # add eax,byte +0x1
#  "\x83\xC0\x02" +                  # add eax,byte +0x2
#
#  "\x01\xD8" +                      # add eax,ebx
#  "\x01\xCB" +                      # add ebx,ecx
#  "\x03\x03" +                      # add eax,[ebx]
#  "\x03\x01" +                      # add eax,[ecx]
#  "\x03\x43\x01" +                  # add eax,[ebx+0x1]
#  "\x8D\x43\x01" +                  # lea eax,[ebx+0x1]
#  "\x03\x04\x1B" +                  # add eax,[ebx+ebx]
#  "\x8D\x04\x1B" +                  # lea eax,[ebx+ebx]
#  "\x03\x44\x1B\x01" +              # add eax,[ebx+ebx+0x1]
#  "\x8D\x44\x1B\x01" +              # lea eax,[ebx+ebx+0x1]
#  "\x03\x04\x9D\x00\x00\x00\x00" +  # add eax,[ebx*4+0x0]
#  "\x8D\x04\x9D\x00\x00\x00\x00" +  # lea eax,[ebx*4+0x0]
#  "\x03\x04\x9D\x01\x00\x00\x00" +  # add eax,[ebx*4+0x1]
#  "\x8D\x04\x9D\x01\x00\x00\x00"    # lea eax,[ebx*4+0x1]
#
#
#puts disassemble_x86(code, 32).inspect
