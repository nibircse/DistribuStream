package org.pdtp;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.net.URLDecoder;
import java.nio.channels.Channels;
import java.nio.channels.ReadableByteChannel;
import java.util.Properties;

import org.pdtp.wire.ChangePort;
import org.pdtp.wire.Range;
import org.pdtp.wire.TellInfo;
import org.pdtp.wire.Transfer;

public class Link extends Thread {
  public Link(Endpoint endpoint, int peerPort) {
    this.endpoint = endpoint;
    this.running = true;
    this.peerPort = peerPort;
    
    if(peerPort > 0) {
      try {
        this.peerServer = new PeerServer(peerPort);
        send(new ChangePort(peerPort));
      } catch (IOException e) {
        e.printStackTrace();
      }
    }
  }
  
  @Override
  public void run() {
    while(running) {
      Object packet;
      try {
        packet = endpoint.take();
        dispatch(packet);        
      } catch (IOException e) {
        e.printStackTrace();
        running = false;
      }
    }
  }
  
  private synchronized <X> void dispatch(X c) {
    // System.out.println("Dispatching " + c);
    if(handler != null) {
      if(c instanceof TellInfo) {
        TellInfo inf = (TellInfo) c;
        if(inf.size != 0)
          handler.infoReceived(inf);
      } else if(c instanceof Transfer) {
        handler.transferCommand((Transfer) c);
      }
    }
  }   
  
  public void send(Object packet) throws IOException {
    endpoint.send(packet);
  }
  
  public void setResourceHandler(ResourceHandler handler) {
    this.handler = handler;
  }

  private class PeerServer extends NanoHTTPD {
    public PeerServer(int port) throws IOException {
      super(port);
    }

    @Override
    public Response serve( String uri, String method,
        Properties header, Properties parms ) {
      try {
        if("GET".equalsIgnoreCase(method)) {
          // Cut away the leading '/'.      
          uri = uri.substring(1);
          uri = URLDecoder.decode(uri, "utf-8");
        
          TellInfo info = handler.getInfoCached(uri);          
          Response response = new Response();
          
          response.header.setProperty("Content-Type", info.mimeType);
          Range range = Range.parseHTTPRange(header.getProperty("Range"));          
          if(range == null) {
            if(info != null) {
              response.status = NanoHTTPD.HTTP_OK;
              range = new Range(0, info.size);
            }
          } else {
            response.status = "206 Partial Content";
            response.header.setProperty("Content-Range",
                "bytes " + range + "/" + (info != null ? info.size : "*")); 
          }
          
          Resource r = new Resource(uri, range);
          ReadableByteChannel ch = handler.getCached(r);
          if(ch == null) {
            response.status = NanoHTTPD.HTTP_NOTFOUND;
            response.data = new ByteArrayInputStream("Not found.".getBytes());
          } else {
            response.data = Channels.newInputStream(ch);
          }
          
          return response;
        } else {
          return new Response(NanoHTTPD.HTTP_NOTIMPLEMENTED,
              "text/plain", "Method " + method + "unsupported.");
        }
      } catch(Exception ex) {
        return new Response(NanoHTTPD.HTTP_INTERNALERROR,
            "text/plain", ex.toString());
      }
    }
  }

  private boolean running;
  private Endpoint endpoint;
  private ResourceHandler handler;
  private int peerPort;
  protected PeerServer peerServer;
}