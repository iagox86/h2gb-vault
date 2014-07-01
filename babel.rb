$LOAD_PATH << File.dirname(__FILE__)

require 'sinatra'
#require 'sinatra/activerecord'

require 'fileutils'
require 'json'
require 'securerandom'
require 'tempfile'

require 'pp' # debug

require 'elf'
require 'pe'

require 'x86'

UUID = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"

## Database stuff
#ActiveRecord::Base.establish_connection(
#  :adapter => 'sqlite3',
#  :host    => nil,
#  :username => nil,
#  :password => nil,
#  :database => 'data.db',
#  :encoding => 'utf8',
#)

# Sinatra stuff
set :show_exceptions, false
set :bind, "0.0.0.0"
set :port, 4567

UPLOADS = File.dirname(__FILE__) + "/uploads/"
FileUtils.mkdir_p(UPLOADS)

def get_temp_file(params)
  if(params['file'].is_a?(Hash))
    file = params['file']
    puts(file[:tempfile])

    if(!file[:tempfile].nil?)
      yield file[:tempfile]
    elsif(!file['tempfile'].nil?)
      yield file[:tempfile]
    else
      raise(Exception, "Couldn't figure out the filename for the uploaded file")
    end
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
    yield(params['file'][:tempfile].read())
  else
    yield(params['file'])
  end
end

def id_to_file(id, verify = false)
  if(id !~ /^#{UUID}$/)
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

def file_to_data(file, params)
  size   = params['size']   ? params['size'].to_i   : nil
  offset = params['offset'] ? params['offset'].to_i : nil

  return IO.read(file, size, offset)
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

def handle_file_request(request, file, id, params)
  case request
  when 'download'
    headers({ 'Content-Disposition' => 'Attachment' })

    data = file_to_data(file, params)

    return {
      :status => 0,
      :file => Base64.encode64(data)
    }
  when 'disassemble'
    data = file_to_data(file, params)
    return {:instructions => disassemble_x86(data, 32)}
  when 'symbols'
    parsed = parse(file, :format => params['format'], :id => id)
    return {:symbols => parsed[:symbols]}
  when 'imports'
    parsed = parse(file, :format => params['format'], :id => id)
    return {:imports => parsed[:imports]}
  when 'exports'
    parsed = parse(file, :format => params['format'], :id => id)
    return {:exports => parsed[:exports]}
  when 'parse'
    return parse(file, :format => params['format'], :id => id)
  else
    raise(Exception, "Unknown request")
  end
end
# Add important headers and encode everything as JSON
after do
  if(response.content_type.nil?)
    content_type 'application/json'
  end

  headers({ 'X-Frame-Options' => 'DENY' })

  if(response.content_type =~ /json/)
    # Default to a good status
    if(response.body[:status].nil?)
      response.body[:status] = 0
    end

    # Convert the response to json
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
  return "Welcome to h2gb! If you don't know why you're seeing this, you probably don't need to be here :)"
end

post '/upload' do
  get_file_data(params) do |data|
    id = SecureRandom.uuid
    File.open(id_to_file(id), "wb") do |f|
      f.write(data)
      f.close()
    end

    return {
      :status => 0,
      :id => id,
    }
  end
end

get('/list') do
  list = []
  Dir.entries(UPLOADS).each() do |e|
    if(e =~ /^#{UUID}$/)
      list << e
    end
  end
  return list
end


# Handle most file-oriented requests with an id built in
get(/^\/([a-z]+)\/(#{UUID})$/) do |request, id|
  return handle_file_request(request, id_to_file(id), id, params)
end

# Handle most file-oriented requests that work on a temp file
post(/^\/([a-z]+)\/upload$/) do |request|
  get_temp_file(params) do |file|
    return handle_file_request(request, file, nil, params)
  end
end

post '/upload_html' do
  content_type 'text/html'

  get_file_data(params) do |data|
    id = SecureRandom.uuid
    File.open(id_to_file(id), "wb") do |f|
      f.write(data)
      f.close()
    end

    redirect to('/static/test.html#' + id)
  end
end

get(/^\/static\/([a-zA-Z0-9_-]+\.[a-zA-Z0-9_-]+)$/) do |file|
  if(file =~ /\.html$/)
    content_type "text/html"
  elsif(file =~ /\.js$/)
    content_type "text/javascript"
  else
    raise(Exception, "Unknown filetype")
  end

  return IO.read(File.dirname(__FILE__) + "/static/#{file}")
end
