require 'marc'
module MARC
  class Reader
    # Stores file byte offset locations for each record.
    #
    # The nth (one-indexed) record starts at offsets[n-1] and ends at
    # offsets[n].
    # This is populated when iterating through the Reader using
    # Reader#each_with_offset_caching or when accessing a not-yet-seen
    # record through Reader#[]
    def offsets
      @offsets ||= [0]
    end

    # Iterates through records and caches byte offset locations of each
    # record.
    # With yield_raw: true yields raw byte strings (like each_raw)
    # rather than MARC::Record objects.
    def each_with_offset_caching(yield_raw: false)
      unless block_given?
        return self.enum_for(:each_with_offset_caching)
      else
        @handle.rewind
        i = 0
        self.each_raw do |raw|
          offsets << @handle.pos if offsets.length < i + 2
          i += 1
          if yield_raw
            yield raw
          else
            yield decode(raw)
          end
        end
      end
    end

    # Access a record by index of record's position in the file
    def [](i)
      if i.negative?
        raise IndexError, "negative indexes are not allowed here"
      end

      if offsets.length > i + 1
        @handle.seek(offsets[i])
        decode(@handle.read(offsets[i+1] - offsets[i]))
      else
        rec_ct = offsets.length - 1
        @handle.seek(offsets.last)
        if @handle.eof?
          raise IndexError.new(
            "index #{i} out of record bounds: 0...#{offsets.length-2}"
          )
        end
        each_raw do |raw|
          offsets << @handle.pos
          rec_ct += 1
          break if rec_ct == i
        end
        self[i]
      end
    end
  end
end
