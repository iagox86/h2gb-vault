require 'base64'
require 'metasm'

def parse_pe(filename, id)
  pe = {
    :format => "PE"
  }

  e = Metasm::PE.decode_file(filename)

  # Header
  pe[:header] = {
    :base         => e.optheader.image_base,
    :sect_align   => e.optheader.sect_align,
    :code_size    => e.optheader.code_size,
    :data_size    => e.optheader.data_size,
    :entrypoint   => e.optheader.entrypoint,
    :base_of_code => e.optheader.base_of_code,
  }

  # Segments TODO

  # Sections
  pe[:sections] = []
  e.sections.each do |s|
    section = {
      :name        => s.name,
      :addr        => s.virtaddr,
      :flags       => s.characteristics,
      :file_offset => s.rawaddr,
      :file_size   => s.rawsize,
    }

    # Only do this if they requested the file data
    if(id.nil?)
      section[:data] = Base64.encode64(IO.read(filename, section[:file_size], section[:file_offset]))
    else
      section[:data_ref] = "#{id}?offset=#{section[:file_offset]}&size=#{section[:file_size]}"
    end

    pe[:sections] << section
  end

  pe[:imports] = {}
  e.imports.each do |import_directory|
    pe[:imports][import_directory.libname] = []
    import_directory.imports.each do |import|
      pe[:imports][import_directory.libname] << {
        :name   => import.name,
        :hint   => import.hint,
        :target => import.target,
      }
    end
  end

  pe[:exports] = []
  if(!e.export.nil?)
    e.export.exports.each do |export|
      pe[:exports] << {
        :ordinal        => export.ordinal,
        :forwarder_lib  => export.forwarder_lib,
        :forwarder_name => export.forwarder_name,
        :name           => export.name,
      }
    end
  end

  return pe
end
