$LOAD_PATH << File.dirname(__FILE__)

require 'sinatra'
require 'sinatra/activerecord'

require 'securerandom'

require 'formats/elf'
require 'formats/pe'
require 'formats/raw'

require 'arch/x86'
require 'arch/x64'

# Debug
require 'pp'

class Binary < ActiveRecord::Base
  # Because I'm using UUIDs for the primary key, this needs to be defined
  self.primary_key = :id

  # Tell ActiveRecord to serialize the instructions field
  self.serialize(:instructions)

  UPLOAD_PATH = File.dirname(__FILE__) + "/uploads"

  include ELF
  include PE
  include Raw

  def initialize(params)
    # Keep track of the 'data' field separately
    @data = params.delete(:data)

    # Create a UUID instead of using a 'real' id
    params[:id] = SecureRandom.uuid

    # Call the parent
    super
  end

  # Overwrite 'save' to save the data to the disk
  def save()
    super()

    # Write the data to the disk
    if(@data)
      File.open(self.filename, "wb") do |f|
        f.write(@data)
        f.close()
      end
    end
  end

  def destroy()
    file = self.filename()
    File.delete(file)

    super()
  end

  def filename()
    return Binary::UPLOAD_PATH + '/' + self.id
  end

  def data(offset = nil, size = nil)
    return IO.read(self.filename(), size, offset)
  end

  def format()
    header = IO.read(filename, 4, 0)

    if(header == "\x7FELF")
      return "ELF"
    elsif(header == "MZ\x90\x00")
      return "PE"
    else
      return "raw"
    end
  end

  def details()

    if(@details)
      return @details
    end

    fmt = format()

    if(fmt == "ELF")
      @details = parse_elf()
    elsif(fmt == "PE")
      @details = parse_pe()
    elsif(fmt == "raw")
      @details = parse_raw()
    else
      raise NotImplementedError
    end

    return @details
  end

end
