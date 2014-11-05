$LOAD_PATH << File.dirname(__FILE__)

require 'model'

require 'sinatra'
require 'sinatra/activerecord'

require 'securerandom'

class Binary < ActiveRecord::Base
  attr_accessor :data
  include Model

  # Because I'm using UUIDs for the primary key, this needs to be defined
#  self.primary_key = :id
  self.has_many(:workspaces)

  UPLOAD_PATH = File.dirname(__FILE__) + "/uploads"

  def initialize(params)
    # Keep track of the 'data' field separately
    @data = params.delete(:data)
    if(@data.nil?)
      raise(Exception, "No data was provided")
    end

    # Create a UUID instead of using a 'real' id
#    params[:id] = SecureRandom.uuid

    # Call the parent
    super(params)
  end

  after_find do
    @data = IO.read(self.filename())
  end

  # Overwrite 'save' to save the data to the disk
  def save()
    super()

    puts()
    puts(self.inspect)
    puts()

    File.open(self.filename, "wb") do |f|
      f.write(@data)
      f.close()
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

  def to_json(params = {})
    result = {
      :binary_id  => self.id,
      :name       => self.name,
      :comment    => self.comment,
    }

    if(params[:skip_data] != true)
      result[:data] = Base64.encode64(self.data)
    end

    return result
  end
end
