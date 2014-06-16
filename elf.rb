require 'base64'
require 'metasm'

def parse_elf(filename, id)
  elf = {
    :format => "ELF"
  }

  e = Metasm::ELF.decode_file(filename)

  # Header
  elf[:header] = {
    :entrypoint => e.header.entry,
  }

  # Segments
  elf[:segments] = []
  e.segments.each do |s|
    segment = {
      :type   => s.type,
      :offset => s.offset,
      :vaddr  => s.vaddr,
      :size   => s.filesz,
      :flags  => s.flags,
      :align  => s.align,
    }

    elf[:segments] << segment
  end

  # Sections
  elf[:sections] = []
  e.sections.each do |s|
    section = {
      :name        => s.name,
      :addr        => s.addr,
      :flags       => s.flags,
      :file_offset => s.offset,
      :file_size   => s.size,
    }

    # Only do this if they requested the file data
    if(id.nil?)
      section[:data] = Base64.encode64(IO.read(filename, s.size, s.offset))
    else
      section[:data_ref] = "#{id}?offset=#{s.offset}&size=#{s.size}"
    end

    elf[:sections] << section
  end

  # Relocations
  elf[:relocations] = []
  e.relocations.each do |s|

    relocation = {
      :name   => s.symbol.name,
      :offset => s.offset,
      :type   => s.type,
      :bind   => s.symbol.bind,
    }

    elf[:relocations] << relocation
  end

  return elf
end

