Dir.chdir('incoming_marc')

Dir.glob("*.{mrc,mrk,zip}").each { |filename|
  pieces = filename.split('.')
  pieces.shift
  pieces.shift
  updatetype = pieces.shift
  filetype = pieces.pop
  filedate = pieces.shift
  filedate.gsub!(/[A-Z]/, '')
  filetime = pieces.shift
  if pieces.size == 2
    segment = pieces.shift
  else
    segment = '_'
  end
  order = pieces.shift
  newname = "#{segment}_#{filedate}_ORIG_#{updatetype}_#{order}.#{filetype}"
  File.rename(filename, newname)

}


