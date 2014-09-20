$LOAD_PATH << File.dirname(__FILE__)

require 'sinatra'
require 'sinatra/activerecord'

require 'models'

require 'fileutils'
require 'json'
require 'securerandom'
require 'tempfile'

require 'pp' # debug

require 'elf'
require 'pe'

require 'x86'

# Database stuff
ActiveRecord::Base.establish_connection(
  :adapter => 'sqlite3',
  :host    => nil,
  :username => nil,
  :password => nil,
  :database => 'data.db',
  :encoding => 'utf8',
)

# Sinatra stuff
set :show_exceptions, false
set :bind, "0.0.0.0"
set :port, 4567

UPLOADS = File.dirname(__FILE__) + "/uploads/"
FileUtils.mkdir_p(UPLOADS)

class Babel < Sinatra::Base
  def get_temp_file(params)
    if(params['file'].is_a?(Hash))
      yield params['tempfile']
    else
      file = Tempfile.new('h2gb-babel')
      file.write(params['file'])
      file.close()

      yield file.path

      file.unlink()
    end
  end

  def get_file_data(params)
    if(params['file'].is_a?(Hash))
      yield(params['file']['filename'], params['file'][:tempfile].read(), nil, params['comment'])
    else
      yield(params['file'], params['filename'], nil, params['comment'])
    end
  end

  def try_get()
    return {
      :status => 404,
      :msg    => "Try using GET!"
    }
  end

  def try_post()
    return {
      :status => 404,
      :msg    => "Try using POST!"
    }
  end

  def add_status(table, status = 0)
    table[:status] = status

    return table
  end

  def id_to_file(id, verify = false)
    if(id !~ /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/)
      raise(Exception, "Bad UUID")
    end

    file = UPLOADS + id
    if(verify && !File.exists?(file))
      raise(Exception, "File not found")
    end

    return UPLOADS + id
  end

  def id_to_data(id, params)
    size   = params['size']   ? params['size'].to_i   : nil
    offset = params['offset'] ? params['offset'].to_i : nil

    return IO.read(id_to_file(id, true), size, offset)
  end

  def parse(filename, options = {})
    format = options[:format]
    id     = options[:id]

    if(format.nil?)
      header = IO.read(filename, 4, 0)
      if(header == "\x7FELF")
        return parse_elf(filename, id)
      elsif(header == "MZ\x90\x00")
        return parse_pe(filename, id)
      else
        raise(Exception, "Couldn't auto-determine format for #{filename}")
      end
    else
      format = params['format']
      if(format.downcase() == 'elf')
        return parse_elf(filename, id)
      elsif(format.downcase() == 'pe')
        return parse_pe(filename, id)
      else
        raise(Exception, "Unknown format")
      end
    end
  end

  # Add important headers and encode everything as JSON
  after do
    if(response.content_type.nil?)
      content_type 'application/json'
    end

    headers({ 'X-Frame-Options' => 'DENY' })

    if(response.content_type =~ /json/)
      response.body = JSON.pretty_generate(response.body) + "\n"
    end
  end

  # Handle errors (exceptions and stuff)
  error do
    status 200

    return {
      :status => 400,
      :msg => env['sinatra.error']
    }
  end

  # Handle file-not-found errors
  not_found do
    status 404

    return {
      :status => 404,
      :msg => "Not found"
    }
  end

  get '/' do
    return "Welcome to h2gb!"
  end

  def binary_upload(filename, data, parent_id, comment)
    # Generate an id for it
    id = SecureRandom.uuid

    # Write to a file named after that id
    new_filename = id_to_file(id)
    File.open(new_filename, "wb") do |f|
      f.write(data)
      f.close()
    end

    # Create an entry in the database
    b = Binary.new(:name => filename, :filename => new_filename, :parent_id => parent_id, :comment => comment)
    b.save()

    return b.id()
  end

  post '/upload_html' do
    content_type 'text/html'

    get_file_data(params) do |filename, data, parent_id, comment|
      id = binary_upload(filename, data, parent_id, comment)
      redirect to('/static/test.html#' + id.to_s())
    end
  end

  post '/upload' do
    get_file_data(params) do |filename, data, parent_id, comment|
      id = binary_upload(filename, data, parent_id, comment)

      return {
        :status => 0,
        :id => id,
      }
    end
  end

  get '/upload' do
    return try_post()
  end

  get(/^\/download\/([a-fA-F0-9-]+)$/) do |id|

    headers({ 'Content-Disposition' => 'Attachment' })

    data = id_to_data(id, params)

    return {
      :status => 0,
      :file => Base64.encode64(data)
    }
  end
  post(/\/download/) do
    return try_get()
  end

  get(/^\/parse\/([a-fA-F0-9-]+)$/) do |id|
    file = id_to_file(id, true)
    parsed = parse(file, :format => params['format'], :id => id)
    return add_status(parsed, 0)
  end

  post('/parse') do
    get_temp_file do |filename|
      parsed = parse(filename, :format => params['format'])
      return add_status(parsed, 0)
    end
  end

  get(/^\/disasm\/x86\/([a-fA-F0-9-]+)/) do |id|
    data = id_to_data(id, params)

    result = {
      :instructions => disassemble_x86(data, 32)
    }

    return add_status(result, 0)
  end

  get(/^\/disasm\/x64\/([a-fA-F0-9-]+)/) do |id|
    data = id_to_data(id, params)

    result = {
      :instructions => disassemble_x86(data, 64)
    }


    return add_status(result, 0)
  end

  get('/list') do
    list = []
    Dir.entries(UPLOADS).each() do |e|
      if(e =~ /[a-fA-F0-9-]+/)
        list << e
      end
    end
    return list
  end

  get(/\/static\/([a-zA-Z0-9_-]+\.[a-zA-Z0-9_-]+)/) do |file|
    if(file =~ /\.html$/)
      content_type "text/html"
    elsif(file =~ /\.js$/)
      content_type "text/javascript"
    else
      raise(Exception, "Unknown filetype")
    end

    return IO.read(File.dirname(__FILE__) + "/static/#{file}")
  end
end
