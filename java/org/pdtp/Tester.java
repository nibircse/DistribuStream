package org.pdtp;

import java.io.IOException;
import java.util.HashMap;
import java.util.Map;

import static java.lang.System.out;

import org.json.JSONException;

public class Tester {
  public static void main(String[] args) {    
    try {
      Network N = new Network("catclops.clickcaster.com", 6000, new MemoryCache());
      out.println("info:" + N.getInfo("pdtp://bla.com/test2.txt"));
      InputStream i = N.get("pdtp://bla.com/test2.txt");
      
      int b = i.read();
      while(b != -1) {
        System.out.print(b);
        b = i.read();
      } 
    } catch (IOException e) {
      // TODO Auto-generated catch block
      e.printStackTrace();
    }
  }
}
