# workspace.rb
# Created November 4, 2014
# By Ron Bowes

require 'model'
require 'sinatra/activerecord'

class Workspace < ActiveRecord::Base
  include Model

  belongs_to(:binary)
  has_many(:views)
  serialize(:settings, Hash)

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

  def to_json(params = {})
    return {
      :workspace_id => self.id,
      :binary_id    => self.binary_id,
      :name         => self.name,
      :settings     => self.settings
    }
  end
end
