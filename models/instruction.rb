$LOAD_PATH << File.dirname(__FILE__)

require 'sinatra'
require 'sinatra/activerecord'

require 'formats/elf'
require 'formats/pe'
require 'formats/raw'

require 'arch/x86'
require 'arch/x64'

class Instruction < ActiveRecord::Base
  belongs_to :binary

  serialize :operands, Array
  serialize :refs, Array
  serialize :xrefs, Array

  def initialize(params)
    # Call the parent
    super
  end
end
