$LOAD_PATH << '.'
require 'csv'
require 'marc'
require 'marc_record'
#require 'marc_extended'
require 'json'
require "highline/import"

require "net/http"

some001s = ['50031679wcm', 'ocm50031679', 'kan1158587']


some001s.each do |id|
  puts ClassicCatalog::OCLCLookup.new(id).under_authority_control?
end
  
  
