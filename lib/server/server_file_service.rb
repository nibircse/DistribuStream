#--
# Copyright (C) 2006-07 ClickCaster, Inc. (info@clickcaster.com)
# All rights reserved.  See COPYING for permissions.
# 
# This source file is distributed as part of the 
# DistribuStream file transfer system.
#
# See http://distribustream.rubyforge.org/
#++

require "uri"    
require "pathname"
require "digest/sha2"
require File.dirname(__FILE__)+'/../common/file_service_base.rb'    

#The server specific file utilities
class ServerFileInfo < FileInfo
  attr_accessor :path

  #Return a raw string of chunk data. The range parameter is local to this chunk
  #and zero based
  def chunk_data(chunkid,range=nil)
    begin
      range=0..chunk_size(chunkid)-1 if range==nil # full range of chunk if range isnt specified
      raise if range.first <0 or range.last>=chunk_size(chunkid)
      start=range.first+chunkid*@base_chunk_size 
      size=range.last-range.first+1 
      file=open( @path)
      file.pos=start
      return file.read(size)
    rescue
      return nil
    end
  end

  #reads the specified byte range from the file and returns it as a string
  def read(range)
    #puts "READING: range=#{range}"
    begin
      file=open(@path)
      file.pos=range.first
      return file.read(range.last-range.first+1)
    rescue Exception=>e
      #puts "e=#{e}"
      return nil
    end
  end 
end

#The file service provides utilities for determining various information about files.
class ServerFileService < FileServiceBase
  attr_accessor :root,:default_chunk_size

  def initialize     
    @root=""
    @default_chunk_size = 512
  end

  def get_info(url)
    begin
      host=URI.split(url)[2]
      #FIXME we should check host against a list of known hosts here
      info=ServerFileInfo.new
      info.streaming=false
      info.base_chunk_size=@default_chunk_size
      info.path=get_local_path(url)
      raise if File.directory?(info.path)
      info.file_size=File.size?( info.path )
      return nil if info.file_size==0 or info.file_size==nil
    rescue
      return nil
    end
    return info
  end 

  #returns the path of this file on the local filesystem
  def get_local_path(url)
    path=URI.split(url)[5]
    path=path[1..path.size-1] #remove leading /
    return (Pathname.new(@root) + path).to_s  
  end

  #returns the SHA256 hash of the specified chunk
  def get_chunk_hash(url,chunk_id)
    return Digest::SHA256.hexdigest( get_info(url).chunk_data(chunk_id) ) rescue nil
  end
end