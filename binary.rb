$LOAD_PATH << File.dirname(__FILE__)

require 'sinatra'
require 'sinatra/activerecord'

require 'securerandom'

class Binary < ActiveRecord::Base
  # Because I'm using UUIDs for the primary key, this needs to be defined
#  self.primary_key = :id
  self.has_many(:workspaces)

  UPLOAD_PATH = File.dirname(__FILE__) + "/uploads"

  def initialize(params)
    # Keep track of the 'data' field separately
    @data = params.delete(:data)
    if(@data.nil?)
      raise Exception, "ERROR"
    end

    # Create a UUID instead of using a 'real' id
#    params[:id] = SecureRandom.uuid

    # Call the parent
    super(params)
  end

  # Overwrite 'save' to save the data to the disk
  def save()
    super()

    puts()
    puts(self.inspect)
    puts()

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
    return Binary::UPLOAD_PATH + '/' + self.id().to_s()
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
end
