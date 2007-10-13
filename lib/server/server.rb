#--
# Copyright (C) 2006-07 ClickCaster, Inc. (info@clickcaster.com)
# All rights reserved.  See COPYING for permissions.
# 
# This source file is distributed as part of the 
# DistribuStream file transfer system.
#
# See http://distribustream.rubyforge.org/
#++

require File.dirname(__FILE__) + '/client_info'
require File.dirname(__FILE__) +'/transfer'
require "thread"

module PDTP
  # PDTP server implementation
  class Server
    attr_reader :connections
    attr_accessor :file_service
    def initialize()
      @connections = Array.new
      @stats_mutex=Mutex.new
      @used_client_ids=Hash.new #keeps a list of client ids in use, they must be unique
      @updated_clients=Hash.new #a set of clients that have been modified and need transfers spawned
    end

    #called by pdtp_protocol when a connection is created
    def connection_created(connection)
      @stats_mutex.synchronize do
        @@log.info("Client connected: #{connection.get_peer_info.inspect}")
        connection.user_data=ClientInfo.new
        @connections << connection 
      end
    end  

    #called by pdtp_protocol when a connection is destroyed
    def connection_destroyed(connection)
      @stats_mutex.synchronize do
        @@log.info("Client connection closed: #{connection.get_peer_info.inspect}")
        @connections.delete(connection)
      end
    end

    # returns the ClientInfo object associated with this connection
    def client_info(connection)
      return connection.user_data ||= ClientInfo.new
    end

    # called when a transfer either finishes, successfully or not
    def transfer_completed(transfer,connection,chunk_hash,send_response=true)      

      # did the transfer complete successfully?
      local_hash=@file_service.get_chunk_hash(transfer.url,transfer.chunkid)

      c1=client_info(transfer.taker)
      c2=client_info(transfer.giver)

      if connection==transfer.taker then
        success= (chunk_hash==local_hash)

        if success then
          #the taker now has the file, so he can provide it
          client_info(transfer.taker).chunk_info.provide(transfer.url,transfer.chunkid..transfer.chunkid)
          c1.trust.success(c2.trust)
        else
          #transfer failed, the client still wants the chunk
          client_info(transfer.taker).chunk_info.request(transfer.url,transfer.chunkid..transfer.chunkid)
          c1.trust.failure(c2.trust)
        end 

        msg={
          "type"=>"hash_verify",
          "url"=>transfer.url,
          "range"=>transfer.byte_range,
          "hash_ok"=>success
        }
        transfer.taker.send_message(msg) if send_response

      end

      #outstr="#{@ids[transfer.giver]}->#{@ids[transfer.taker]} transfer completed: #{transfer}"
      #outstr=outstr+" t->g=#{c1.trust.weight(c2.trust)} g->t=#{c2.trust.weight(c1.trust)}" 
      #outstr=outstr+"sent_by: "+ ( connection==transfer.taker ? "taker" : "giver" )
      #outstr=outstr+" success=#{success} "
      #@@log.debug(outstr)

      #remove this transfer from whoever sent it
      client_info(connection).transfers.delete(transfer.transfer_id)
      @updated_clients[connection]=true #flag this client for transfer creation
    end

    #Creates a new transfer between two peers
    #returns true on success, or false if the specified transfer is already in progress
    def begin_transfer(taker,giver,url,chunkid)
      byte_range=@file_service.get_info(url).chunk_range(chunkid) 
      t=Transfer.new(taker,giver,url,chunkid,byte_range)

      #make sure this transfer doesnt already exist
      t1=client_info(taker).transfers[t.transfer_id]
      t2=client_info(giver).transfers[t.transfer_id]
      if t1 != nil or t2 != nil then
        return false
      end

      client_info(taker).chunk_info.transfer(url,chunkid..chunkid) 

      client_info(taker).transfers[t.transfer_id]=t
      client_info(giver).transfers[t.transfer_id]=t

      #send transfer message to the connector
      addr,port=t.acceptor.get_peer_info
      request={
        "type"=>"transfer",
        "host"=>addr,
        "port"=>t.acceptor.user_data.listen_port,
        "method"=> (t.connector == t.taker ? "get" : "put"),
        "url"=>url,
        "range"=>byte_range,
        "peer_id"=>client_info(t.acceptor).client_id
      }

      t.connector.send_message(request)
      return true
    end

    #this function removes all stalled transfers from the list
    #and spawns new transfers as appropriate
    #it must be called periodically by EventMachine
    def clear_all_stalled_transfers
      @connections.each do |c|
        clear_stalled_transfers_for_client(c)  
      end
      spawn_all_transfers    
    end

    #removes all stalled transfers that this client is a part of
    def clear_stalled_transfers_for_client(client_connection)
      info=client_info(client_connection)
      info.get_stalled_transfers.each do |t|
        transfer_completed(t,client_connection,nil,false)
      end  
    end

    #spawns uploads and downloads for this client.
    #should be called every time there is a change that would affect 
    #what this client has or wants
    def spawn_transfers_for_client(client_connection)
      info=client_info(client_connection)

      while info.wants_download? do
        break if spawn_download_for_client(client_connection) == false
      end

      while info.wants_upload? do
        break if spawn_upload_for_client(client_connection) == false
      end
    end

    #creates a single download for the specified client
    #returns true on success, false on failure
    def spawn_download_for_client(client_connection)
      feasible_peers=[]

      c1info=client_info(client_connection)
      begin
        url,chunkid=c1info.chunk_info.high_priority_chunk
      rescue
        return false
      end

      @connections.each do |c2|
        next if client_connection==c2
        next if client_info(c2).wants_upload? == false
        if client_info(c2).chunk_info.provided?(url,chunkid) then
          feasible_peers << c2
          break if feasible_peers.size > 5
        end
      end

      # we now have a list of clients that have the requested chunk.
      # pick one and start the transfer
      if feasible_peers.size>0 then
        #FIXME base this on the trust model
        giver=feasible_peers[rand(feasible_peers.size)]
        return begin_transfer(client_connection,giver,url,chunkid)
        #FIXME should we try again if begin_transfer fails?
      end

      return false
    end

    #creates a single upload for the specified client
    #returns true on success, false on failure
    def spawn_upload_for_client(client_connection)
      c1info=client_info(client_connection)

      @connections.each do |c2|
        next if client_connection==c2
        next if client_info(c2).wants_download? == false

        begin
          url,chunkid=client_info(c2).chunk_info.high_priority_chunk
        rescue
          next
        end

        if c1info.chunk_info.provided?(url,chunkid) then
          return begin_transfer(c2,client_connection,url,chunkid)
        end
      end

      return false
    end

    #called by pdtp_protocol for each message that comes in from the wire
    def dispatch_message(message,connection)
      @stats_mutex.synchronize do
        dispatch_message_needslock(message,connection)
      end
    end

    #creates new transfers for all clients that have been updated
    def spawn_all_transfers
      while @updated_clients.size > 0 do
        tmp=@updated_clients
        @updated_clients=Hash.new
        tmp.each do |client,true_key| 
          spawn_transfers_for_client(client)
        end
      end    
    end

    #handles the request, provide, unrequest, unprovide messages
    def handle_requestprovide(connection,message)
      type=message["type"]
      url=message["url"]
      info=@file_service.get_info(url) rescue nil
      raise ProtocolWarn.new("Requested URL: '#{url}' not found") if info.nil?

      exclude_partial= (type=="provide") #only exclude partial chunks from provides
      range=info.chunk_range_from_byte_range(message["range"],exclude_partial)

      #call request, provide, unrequest, or unprovide
      client_info(connection).chunk_info.send( type.to_sym, url, range)
      @updated_clients[connection]=true #add to the list of client that need new transfers
    end

    #handles all incoming messages from clients
    def dispatch_message_needslock(message,connection)
      #require the client to be logged in with a client id
      if message["type"] != "client_info" and client_info(connection).client_id.nil? then
        raise ProtocolError.new("You need to send a 'client_info' message first")
      end 

      case message["type"] 
      when "client_info"
        cid=message["client_id"]
        #make sure this id isnt in use
        if @used_client_ids[cid] then
          raise ProtocolError.new("Your client id: #{cid} is already in use.")   
        else
          @used_client_ids[cid]=true
        end    
        client_info(connection).listen_port=message["listen_port"]
        client_info(connection).client_id=cid
      when "ask_info"
        info=file_service.get_info(message["url"])
        response={
          "type"=>"tell_info",
          "url"=>message["url"]
        }
        unless info.nil?
          response["size"]=info.file_size
          response["chunk_size"]=info.base_chunk_size
          response["streaming"]=info.streaming
        end
        connection.send_message(response)

      when "request"
        handle_requestprovide(connection,message)
      when "provide"
        handle_requestprovide(connection,message)
      when "unrequest"
        handle_requestprovide(connection,message)
      when "unprovide"
        handle_requestprovide(connection,message)
      when "ask_verify"

        #check if the specified transfer is a real one
        my_id=client_info(connection).client_id
        transfer_id=Transfer::gen_transfer_id(my_id,message["peer_id"],message["url"],message["range"])
        ok= client_info(connection).transfers[transfer_id] ? true : false
        client_info(connection).transfers[transfer_id].verification_asked=true if ok
        @@log.debug "AskVerify not ok: id=#{transfer_id}" if ok == false
        response={
          "type"=>"tell_verify",
          "url"=>message["url"],
          "peer_id"=>message["peer_id"],
          "range"=>message["range"],
          "peer"=>message["peer"],
          "is_authorized"=>ok
        }
        connection.send_message(response)

      when "completed"
        my_id=client_info(connection).client_id
        transfer_id=Transfer::gen_transfer_id(my_id,message["peer_id"],message["url"],message["range"])
        transfer=client_info(connection).transfers[transfer_id]
        @@log.debug("Completed: id=#{transfer_id} ok=#{transfer != nil}" )
        if transfer  then
          transfer_completed(transfer,connection,message["hash"])
        else
          raise ProtocolWarn.new("You sent me a transfer completed message for unknown transfer: #{transfer_id}")
        end

      when "protocol_error"
        #ignore
      when "protocol_warn"
        #ignore 
      else
        raise ProtocolError.new("Unhandled message type: #{message['type']}")
      end

      spawn_all_transfers

    end

    #returns a string representing the specified connection
    def connection_name(c)
      #host,port=c.get_peer_info
      #return "#{get_id(c)}: #{host}:#{port}"
      return client_info(c).client_id
    end

    def generate_html_stats
      @stats_mutex.synchronize do
        return generate_html_stats_needslock
      end
    end

    #builds an html page with information about the server's internal workings
    def generate_html_stats_needslock

      s=String.new
      s=s+"<html><head><title>PDTP Statistics</title></head>"
      s=s+"<body>Time=#{Time.new.to_s}<br> Connected Clients=#{@connections.size}"

      s=s+"<center><table border=1>"
      s=s+"<tr><th>Client</th><th>Downloads</th><th>Files</th></tr>"

      @connections.each do |c|

        transfers=""
        client_info(c).transfers.each do |key,t|
          if c==t.giver then
            str="UP: "
            peer=t.taker
          else
            str="DOWN: "
            peer=t.giver
          end

          str=str+" id=#{t.transfer_id}"
          transfers=transfers+str+"<br>"
        end

        files=""
        stats=client_info(c).chunk_info.get_file_stats
        stats.each do |fs|

          files=files+"#{fs.url} size=#{fs.file_chunks} req=#{fs.chunks_requested}"
          files=files+" prov=#{fs.chunks_provided} transf=#{fs.chunks_transferring}<br>"    
        end      

        host,port=c.get_peer_info
        client_name="#{connection_name(c)}<br>#{host}:#{port}"

        s=s+"<tr><td>#{client_name}</td><td>#{transfers}</td><td>#{files}</td></tr>"
      end 

      s=s+"</table>"

      s=s+"</body></html>"

      return s
    end
  end
end