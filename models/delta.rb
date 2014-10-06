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

class Delta < ActiveRecord::Base
  # Because ActiveRecord has issues with the pluralization...
  self.table_name = "deltas"

  # Tell ActiveRecord to serialize the instructions field
  self.serialize(:deltas, Array)

  # Relationship to a project
  self.belongs_to(:project)

  def initialize(params)
    super(params)
  end
end
