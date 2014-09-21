$LOAD_PATH << File.dirname(__FILE__)

require 'sinatra'
require 'sinatra/activerecord'

require 'binary'

require 'fileutils'
require 'json'
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

class Babel < Sinatra::Base
  def add_status(table, status = 0)
    table[:status] = status
    return table
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
      headers({ 'Content-Disposition' => 'Attachment' })
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

  post '/upload_html' do
    content_type 'text/html'

    b = Binary.new(
      :name => params['file'][:filename],
      :comment => params['comment'],
      :data => params['file'][:tempfile].read()
    )
    b.save()


    redirect to('/static/test.html#' + b.id)
  end

  post '/upload' do
    b = Binary.new(
      :name    => params['filename'],
      :comment => params['comment'],
      :data    => params['data'],
    )
    b.save()

    return {
      :status => 0,
      :id => b.id,
    }
  end

  get(/^\/download\/([a-fA-F0-9-]+)$/) do |id|

    b = Binary.find(id)
    return {
      :status => 0,
      :name => b.filename,
      :file => Base64.encode64(b.data),
    }
  end

  get(/^\/parse\/([a-fA-F0-9-]+)$/) do |id|
    b = Binary.find(id)

    begin
      parsed = parse(b.filename, :format => params['format'], :id => id)
      return add_status(parsed, 0)
    rescue Exception => e
      return { :status => 1, :error => e.to_s }
    end
  end

  get(/^\/disasm\/x86\/([a-fA-F0-9-]+)/) do |id|
    b = Binary.find(id)

    result = {
      :instructions => disassemble_x86(b.data, 32)
    }

    return add_status(result, 0)
  end

  get(/^\/disasm\/x64\/([a-fA-F0-9-]+)/) do |id|
    b = Binary.find(id)

    result = {
      :instructions => disassemble_x86(b.data, 64)
    }

    return add_status(result, 0)
  end

  get('/binaries') do
    return Binary.all().as_json()
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
