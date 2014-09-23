require 'base64'
require 'metasm'

module Raw
  def parse_raw()
    size = File.size(self.filename)

    out = { }

    # Header
    out[:header] = {
      :format       => "RAW",
      :base         => 0,
      :entrypoint   => 0,
    }

    # Sections
    section = {
        :name        => ".raw",
        :addr        => 0,
        :file_offset => 0,
        :file_size   => size
      }

    out[:sections] = [section]

    return out
  end
end

