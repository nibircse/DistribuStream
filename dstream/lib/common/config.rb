require 'singleton'

class PDTPConfig
	include Singleton

	attr_accessor :host,:port,:file_root,:debug,:log
	
	def initialize 
		@host = '0.0.0.0'
		@port = 6000
		@file_root = File.dirname(__FILE__)+'/../../../testfiles'
		@debug = true
		@log = STDOUT
	end

end