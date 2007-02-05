#require File.dirname(__FILE__) + '/transfer_manager'
require "rubygems"
require "eventmachine"
require File.dirname(__FILE__)+'/../common/pdtp_protocol'
require File.dirname(__FILE__)+'/client_transfer'

class Client
  attr_accessor :file_service
  attr_accessor :server_connection

  def initialize
    @connections=Array.new
    @transfers=Array.new
  end

  def connection_created(connection)
    @connections << connection
  end

  def connection_destroyed(connection)
    @connections.delete(connection)
  end
  

  def dispatch_message(message,connection) 
    if connection==@server_connection then
      dispatch_message_server(message,connection)
    else
      dispatch_message_peer(message,connection)
    end
  end
  
  def dispatch_message_server(message,connection)
    case message["type"]
    when "tell_info"
      info=FileInfo.new
      info.size,info.chunk_size,info.streaming=message["size"],message["chunk_size"],message["streaming"]
      @file_service.set_info(message["url"],info)
    when "transfer"
      puts "got transfer message"
      puts message.inspect
      peer=message["peer"]
      new_con=EventMachine::connect peer[0],peer[1],PDTPProtocol 
     
      transfer_direction=message["transfer_direction"].to_sym
      raise if transfer_direction!=:out and transfer_direction!=:in      

      new_trans=ClientTransfer.new(new_con,message["url"],
        message["chunk_id"],transfer_direction,file_service)

      new_trans.go_ahead=true if transfer_direction==:in #always ready to receive data that the server tells us to
      
      @transfers << new_trans
      new_trans.send_initial_request
    when "tell_verify"
      @transfers.each do |t|

        if t.peer.get_peer_info==message["peer"] and t.url==message["url"] and t.chunkid==message["chunk_id"] then
          # if the server does not authorize the transfer, kill it and the associated connection
          if !message["is_authorized"] then
            @transfers.delete(t)
            t.peer.close_connection
          else
            t.go_ahead=true 
            t.update
          end
 
          break
        end

      end
    else  
      raise "from server: unknown message type: #{message['type']} "
    end
  end

  def dispatch_message_peer(message,connection)
    case message["type"]
    when "give", "take"
      transfer_direction=message["type"]=="give" ? :out : :in
      new_trans=ClientTransfer.new(connection,message["url"],
        message["chunk_id"],transfer_direction,file_service)
      
      @transfers << new_trans      

      askverify={
        "type"=>"ask_verify",
        "peer"=>connection.get_peer_info,
        "url"=>message["url"],
        "chunk_id"=>message["chunk_id"]
      }
      @server_connection.send_message(askverify)
    else
      raise "from peer: unknown message type: #{message['type']} "
    end
  end

  def print_stats
    puts "client: num_connections=#{@connections.size} num_transfers=#{@transfers.size}"
  end

end
    
