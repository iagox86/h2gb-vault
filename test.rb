require 'digest'
require 'httmultiparty'
require 'httparty'

HOST = 'localhost'
PORT = 4567

SERVICE = "http://%s:%s" % [HOST, PORT]

# Upload all the files

puts()
puts("Testing upload")
puts()

files = {}
dir = File.dirname(__FILE__)
Dir.entries(dir + '/examples').each do |file|
  if(file !~ /^elf/ && file !~ /^pe/)
    next
  end

  file = dir + "/examples/" + file

  data = IO.read(file)
  data.force_encoding("ASCII-8BIT") # This is necessary, since it's how the file comes back

  result = HTTMultiParty.post(SERVICE + "/upload", :body => {:file => File.new(file)})
  result = result.parsed_response
  if(result['status'] != 0)
    puts("ERROR:")
    puts(result.inspect)
    exit
  else
    puts("Successfully uploaded #{result['id']}")
  end

  files[result['id']] = data
end

puts()
puts("Testing download")
puts()

files.each_pair do |id, file|
  result = HTTParty.get(SERVICE + "/download/" + id)
  result = result.parsed_response

  remote_file = Base64.decode64(result["file"])

  if(remote_file.to_s != file.to_s)
    puts("File doesn't match for #{id}")
  else
    puts("Successfully downloaded #{id}")
  end
end

puts()
puts("Testing chunked download")
puts()

files.each_pair do |id, file|
  result = HTTParty.get(SERVICE + "/download/" + id + "?size=100&offset=0")
  result = result.parsed_response

  remote_file = Base64.decode64(result["file"])
  if(remote_file != file[0,100])
    puts("First 100 bytes don't match for #{id}")
  else
    puts("Successfully downloaded first 100 bytes of #{id}")
  end
end
files.each_pair do |id, file|
  result = HTTParty.get(SERVICE + "/download/" + id + "?size=100&offset=100")
  result = result.parsed_response

  remote_file = Base64.decode64(result["file"])
  if(remote_file != file[100,100])
    puts("Next 100 bytes don't match for #{id}")
  else
    puts("Successfully downloaded next 100 bytes of #{id}")
  end
end

puts()
puts("Testing parsing uploaded files (some of these will intentionally fail)")
puts()

files.each_pair do |id, file|
  result = HTTParty.get(SERVICE + "/parse/" + id)
  result = result.parsed_response
  if(result['status'] == 0)
    puts("Successfully parsed #{id}")
  else
    puts("Failed to parse #{id}")
    puts(result.inspect)
    exit
  end
end

files.each_pair do |id, file|
  result = HTTParty.get(SERVICE + "/parse/" + id + "?format=elf")
  result = result.parsed_response
  if(result['status'] == 0)
    puts("Successfully parsed #{id}")
  else
    puts("Failed to parse #{id}: #{result.inspect}")
  end
end

files.each_pair do |id, file|
  result = HTTParty.get(SERVICE + "/parse/" + id + "?format=pe")
  result = result.parsed_response
  if(result['status'] == 0)
    puts("Successfully parsed #{id}")
  else
    puts("Failed to parse #{id}: #{result.inspect}")
  end
end

puts()
puts("Testing x86 diassembling (direct)")
puts()

files = {}
dir = File.dirname(__FILE__)
Dir.entries(dir + '/examples').each do |file|
  if(file !~ /^x86/)
    next
  end

  file = dir + "/examples/" + file

  data = IO.read(file)
  data.force_encoding("ASCII-8BIT") # This is necessary, since it's how the file comes back

  result = HTTMultiParty.post(SERVICE + "/disasm/x86/", :body => {:file => File.new(file)})
  result = result.parsed_response
  if(result['status'] != 0)
    puts("ERROR:")
    puts(result.inspect)
    exit
  else
    puts(result.inspect)
  end
end

