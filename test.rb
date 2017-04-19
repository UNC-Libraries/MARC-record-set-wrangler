require 'marc'
require 'benchmark'
require 'pp'
require 'pstore'

RecInfo = Struct.new(:id, :source, :index)

puts "\n\nPopulating rec_info"
in_dir = 'incoming_marc'
rec_info = []
store = PStore.new('working.pstore')

Dir.chdir(in_dir)
infiles = Dir.glob('*.mrc')
if infiles.size > 0
  infiles.each { |file|
    puts "\n\nPopulating rec_info for #{file}"
    puts Benchmark.measure {
      recindex = 0
      MARC::Reader.new(file).each { |rec|
        source = file
        recid = rec['001'].value
        rec_info << RecInfo.new(recid, source, recindex)
        recindex += 1
      }
    }

    puts "\n\nPopulating pstore for #{file}"
    puts Benchmark.measure {
      rawindex = 0
      rawhash = {}
      MARC::Reader.new(file).each_raw { |rec|
        rawhash[rawindex] = rec
        rawindex += 1
      }
      store.transaction {
        store[file] = rawhash
      }
    }
  }
end


get_me_recs = rec_info.group_by { |ri| ri.source }

times = []

get_me_recs.each_pair { |source, infoarr|
    sourcehash = {}
    puts "\n\nGetting pstore for #{source}"
    puts Benchmark.measure {
      store.transaction {
        sourcehash = store[source]
      }
    }
    infoarr.each { |ri|
      times << Benchmark.realtime() {
        rawrec = sourcehash[ri.index]
        rec = MARC::Reader.decode(rawrec)
      }
    }
}

timehash = {}
times.each_with_index { |t, i|
  if timehash.has_key?(t)
    timehash[t] << i
  else
    timehash[t] = [i]
  end
}

times.sort!
puts "Fastest record retrieval: #{times.first} -- rec(s) #{timehash[times.first].join(', ')}"
puts "Slowest record retrieval: #{times.last} -- rec(s) #{timehash[times.last].join(', ')}"

avgtime = times.reduce(:+) / times.size

puts "Average record retrieval: #{avgtime}"

File.delete('working.pstore')
