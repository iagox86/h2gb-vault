require 'sinatra/activerecord'

class Workspace < ActiveRecord::Base
  belongs_to :binary
  has_many :memories
  serialize :settings, Hash

  def initialize(params = {})
    if(params[:settings].nil?)
      params[:settings] = {}
    end
    super(params)
  end

  def set(name, value)
    self.settings[name] = value
  end

  def get(name)
    return self.settings[name]
  end
end
