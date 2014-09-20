require 'base64'
require 'metasm'

def parse_raw(filename, id)
  size = File.size(filename)

  out = { }

  # Header
  out[:header] = {
    :format       => "RAW",
    :base         => 0,
    :entrypoint   => 0,
  }

  # Sections
  section = {
      :name        => "raw",
      :addr        => 0,
      :file_offset => 0,
      :file_size   => size
    }

  # Only do this if they requested the file data
  if(id.nil?)
    section[:data] = Base64.encode64(IO.read(filename))
  else
    section[:data_ref] = "#{id}?offset=#{section[:file_offset]}&size=#{section[:file_size]}"
  end

  out[:sections] = [section]

  return out
end

#puts parse_pe("uploads/fb0e3013-8dda-4d6f-9657-cfc42cee8f25", "uploads/fb0e3013-8dda-4d6f-9657-cfc42cee8f25")
