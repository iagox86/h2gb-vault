require 'sinatra'
require 'sinatra/activerecord'


class Binary < ActiveRecord::Base
  # Because I'm using UUIDs for the primary key, this needs to be defined
  self.primary_key = :id

  UPLOAD_PATH = File.dirname(__FILE__) + "/uploads"

  def filename(basepath = UPLOAD_PATH)
    return basepath + '/' + self.id
  end

  def data(offset = nil, size = nil, basepath = Binary::UPLOAD_PATH)
    return IO.read(self.filename(), size, offset)
  end
end

