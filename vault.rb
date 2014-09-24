$LOAD_PATH << File.dirname(__FILE__)

require 'sinatra'
require 'sinatra/activerecord'

require 'binary'

require 'fileutils'
require 'json'
require 'tempfile'

require 'pp' # debug

# Database stuff
ActiveRecord::Base.establish_connection(
  :adapter => 'sqlite3',
  :host    => nil,
  :username => nil,
  :password => nil,
  :database => 'data.db',
  :encoding => 'utf8',
)

class Vault < Sinatra::Application
  def add_status(status, table)
    table[:status] = status
    return table
  end

  def Vault.COMMAND(c)
    return /^\/#{c}\/([a-fA-F0-9-]+)$/
  end

  # Add important headers and encode everything as JSON
  after do
    if(response.content_type.nil?)
      content_type 'application/json'
    end

    headers({ 'X-Frame-Options' => 'DENY' })

    if(response.content_type =~ /json/)
      headers({
#        'Access-Control-Allow-Origin' => '*', # TODO: Might not need this forever
        'Content-Disposition' => 'Attachment'
      })

      response.body = JSON.pretty_generate(response.body) + "\n"
    end
  end

  # Handle errors (exceptions and stuff)
  error do
    status 200

    return add_status(500,  {:reason => env['sinatra.error'] })
  end

  # Handle file-not-found errors
  not_found do
    status 404

    return add_status(404, {:reason => 'not found' })
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

    return add_status(0, {:id => b.id })
  end

  get('/binaries') do
    return add_status(0, {:binaries => Binary.all().as_json() })
  end

  get(COMMAND('download')) do |id|
    b = Binary.find(id)
    return add_status(0, {
      :name => b.filename,
      :file => Base64.encode64(b.data),
    })
  end

  get(COMMAND('parse')) do |id|
    b = Binary.find(id)

    return add_status(0, b.parse(:format => params['format']))
  end

  get(COMMAND('delete')) do |id|
    b = Binary.find(id)
    b.destroy()
  end

  get(COMMAND('format')) do |id|
    b = Binary.find(id)
    return add_status(0, { format: b.format() })
  end

  get(COMMAND('disassemble')) do |id|
    b = Binary.find(id)

    offset = params['offset']
    length = params['length']
    arch = params['arch']

    if(!offset.nil?)
      offset = offset.to_i()
    end
    if(!length.nil?)
      length = length.to_i()
    end

    return add_status(0, {
      :instructions => b.disassemble(offset, length, arch)
    })
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
