require 'sinatra'
require 'sinatra/activerecord'

require 'securerandom'


class Binary < ActiveRecord::Base
  # Because I'm using UUIDs for the primary key, this needs to be defined
  self.primary_key = :id

  UPLOAD_PATH = File.dirname(__FILE__) + "/uploads"

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

  def filename(basepath = UPLOAD_PATH)
    return basepath + '/' + self.id
  end

  def data(offset = nil, size = nil, basepath = Binary::UPLOAD_PATH)
    return IO.read(self.filename(), size, offset)
  end
end

