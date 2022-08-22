/*
 * Copyright (c) 2017 Jason Lowe-Power
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are
 * met: redistributions of source code must retain the above copyright
 * notice, this list of conditions and the following disclaimer;
 * redistributions in binary form must reproduce the above copyright
 * notice, this list of conditions and the following disclaimer in the
 * documentation and/or other materials provided with the distribution;
 * neither the name of the copyright holders nor the names of its
 * contributors may be used to endorse or promote products derived from
 * this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 * A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
 * OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
 * LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 * DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
 * THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 * OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

/**
 * This file contains the directory controller for MOESI protocol
 * By Referring the MSI protocol mentioned below
 *
 * In Ruby the directory controller both contains the directory coherence state
 * but also functions as the memory controller in many ways. There are states
 * in the directory that are both memory-centric and cache-centric. Be careful!
 *
 * The protocol in this file is based off of the MSI protocol found in
 * A Primer on Memory Consistency and Cache Coherence
 *      Daniel J. Sorin, Mark D. Hill, and David A. Wood
 *      Synthesis Lectures on Computer Architecture 2011 6:3, 141-149
 *
 * Table 8.2 contains the transitions and actions found in this file and
 * section 8.2.4 explains the protocol in detail.
 *
 * See Learning gem5 Part 3: Ruby for more details.
 */

machine(MachineType:Directory, "Directory protocol")
    :
      // This "DirectoryMemory" is a little weird. It is initially allocated
      // so that it *can* cover all of memory (i.e., there are pointers for
      // every 64-byte block in memory). However, the entries are lazily
      // created in getDirEntry()
      DirectoryMemory * directory;
      // You can put any parameters you want here. They will be exported as
      // normal SimObject parameters (like in the SimObject description file)
      // and you can set these parameters at runtime via the python config
      // file. If there is no default here (like directory), it is mandatory
      // to set the parameter in the python config. Otherwise, it uses the
      // default value set here.
      Cycles toMemLatency := 1;

    // Forwarding requests from the directory *to* the caches.
    MessageBuffer *forwardToCache, network="To", virtual_network="1",
          vnet_type="forward";
    // Response from the directory *to* the cache.
    MessageBuffer *responseToCache, network="To", virtual_network="2",
          vnet_type="response";

    // Requests *from* the cache to the directory
    MessageBuffer *requestFromCache, network="From", virtual_network="0",
          vnet_type="request";

    // Responses *from* the cache to the directory
    MessageBuffer *responseFromCache, network="From", virtual_network="2",
          vnet_type="response";

    // Special buffer for memory requests. Kind of like the mandatory queue
    MessageBuffer *requestToMemory;

    // Special buffer for memory responses. Kind of like the mandatory queue
    MessageBuffer *responseFromMemory;

{
    // For many things in SLICC you can specify a default. However, this
    // default must use the C++ name (mangled SLICC name). For the state below
    // you have to use the controller name and the name we use for states.
    state_declaration(State, desc="Directory states",
                      default="Directory_State_I") {
        // Stable states.
        // NOTE: Thise are "cache-centric" states like in Sorin et al.
        // However, The access permissions are memory-centric.
        I, AccessPermission:Read_Write,  desc="Invalid in the caches.";
        S, AccessPermission:Read_Only,   desc="At least one cache has the blk";
        M, AccessPermission:Invalid,     desc="A cache has the block in M";
        E, AccessPermission:Invalid,     desc="A cache has the block in E";
        O, AccessPermission:Read_Only,   desc="One of the block is in O";
        
        // Transient states
        S_D, AccessPermission:Busy,      desc="Moving to S, but need data";

        // Waiting for data from memory
        S_m, AccessPermission:Read_Write, desc="In S waiting for mem";
        E_m, AccessPermission:Read_Write, desc="Moving to E waiting for mem";
        M_m, AccessPermission:Read_Write, desc="Moving to M waiting for mem";

        // Waiting for write-ack from memory
        MI_m, AccessPermission:Busy,       desc="Moving to I waiting for ack";
        SS_m, AccessPermission:Busy,       desc="Moving to S waiting for ack";
    }

    enumeration(Event, desc="Directory events") {
        // Data requests from the cache
        GetS,         desc="Request for read-only data from cache";
        GetMOwner,    desc="Request for read-write data from Owner";
        GetMNonOwner, desc="Request for read-write data from non-owner";
        
        // Writeback requests from the cache
        PutSNotLast,  desc="PutS and the block has other sharers";
        PutSLast,     desc="PutS and the block has no other sharers";
        PutMOwner,    desc="Dirty data writeback from the owner";
        PutMNonOwner, desc="Dirty data writeback from non-owner";
        PutEOwner,    desc="PutE from owner";
        PutENonOwner, desc="PutE from non-owner";
        PutOOwner,    desc="PutO from owner";
        PutONonOwner, desc="PutO from non-owner";
        
        // Cache responses
        Data,         desc="Response to fwd request with data";

        // From Memory
        MemData,      desc="Data from memory";
        MemAck,       desc="Ack from memory that write is complete";
    }

    // NOTE: We use a netdest for the sharers and the owner so we can simply
    // copy the structure into the message we send as a response.
    structure(Entry, desc="...", interface="AbstractCacheEntry", main="false") {
        State DirState,         desc="Directory state";
        NetDest Sharers,        desc="Sharers for this block";
        NetDest Owner,          desc="Owner of this block";
    }

    Tick clockEdge();

    // This either returns the valid directory entry, or, if it hasn't been
    // allocated yet, this allocates the entry. This may save some host memory
    // since this is lazily populated.
    Entry getDirectoryEntry(Addr addr), return_by_pointer = "yes" {
        Entry dir_entry := static_cast(Entry, "pointer", directory[addr]);
        if (is_invalid(dir_entry)) {
            // This first time we see this address allocate an entry for it.
            dir_entry := static_cast(Entry, "pointer",
                                     directory.allocate(addr, new Entry));
        }
        return dir_entry;
    }

    /*************************************************************************/
    // Functions that we need to define/override to use our specific structures
    // in this implementation.
    // NOTE: we don't have TBE in this machine, so we don't need to pass it
    // to these overridden functions.

    State getState(Addr addr) {
        if (directory.isPresent(addr)) {
            return getDirectoryEntry(addr).DirState;
        } else {
            return State:I;
        }
    }

    void setState(Addr addr, State state) {
        if (directory.isPresent(addr)) {
            if (state == State:M) {
                DPRINTF(RubySlicc, "Owner %s\n", getDirectoryEntry(addr).Owner);
                assert(getDirectoryEntry(addr).Owner.count() == 1);
                assert(getDirectoryEntry(addr).Sharers.count() == 0);
            }
            else if (state == State:O || state == State:E) {
                assert(getDirectoryEntry(addr).Owner.count() == 1;
            }
            getDirectoryEntry(addr).DirState := state;
            if (state == State:I)  {
                assert(getDirectoryEntry(addr).Owner.count() == 0);
                assert(getDirectoryEntry(addr).Sharers.count() == 0);
            }
        }
    }

    // This is really the access permissions of memory.
    // TODO: I don't understand this at the directory.
    AccessPermission getAccessPermission(Addr addr) {
        if (directory.isPresent(addr)) {
            Entry e := getDirectoryEntry(addr);
            return Directory_State_to_permission(e.DirState);
        } else  {
            return AccessPermission:NotPresent;
        }
    }
    void setAccessPermission(Addr addr, State state) {
        if (directory.isPresent(addr)) {
            Entry e := getDirectoryEntry(addr);
            e.changePermission(Directory_State_to_permission(state));
        }
    }

    void functionalRead(Addr addr, Packet *pkt) {
        functionalMemoryRead(pkt);
    }

    // This returns the number of writes. So, if we write then return 1
    int functionalWrite(Addr addr, Packet *pkt) {
        if (functionalMemoryWrite(pkt)) {
            return 1;
        } else {
            return 0;
        }
    }


    /*************************************************************************/
    // Network ports

    out_port(forward_out, RequestMsg, forwardToCache);
    out_port(response_out, ResponseMsg, responseToCache);
    out_port(memQueue_out, MemoryMsg, requestToMemory);
    

    in_port(memQueue_in, MemoryMsg, responseFromMemory) {
        if (memQueue_in.isReady(clockEdge())) {
            peek(memQueue_in, MemoryMsg) {
                if (in_msg.Type == MemoryRequestType:MEMORY_READ) {
                    trigger(Event:MemData, in_msg.addr);
                } else if (in_msg.Type == MemoryRequestType:MEMORY_WB) {
                    trigger(Event:MemAck, in_msg.addr);
                } else {
                    error("Invalid message");
                }
            }
        }
    }

    in_port(response_in, ResponseMsg, responseFromCache) {
        if (response_in.isReady(clockEdge())) {
            peek(response_in, ResponseMsg) {
                if (in_msg.Type == CoherenceResponseType:Data) {
                    trigger(Event:Data, in_msg.addr);
                } else {
                    error("Unexpected message type.");
                }
            }
        }
    }

    in_port(request_in, RequestMsg, requestFromCache) {
        if (request_in.isReady(clockEdge())) {
            peek(request_in, RequestMsg) {
                Entry entry := getDirectoryEntry(in_msg.addr);
                if (in_msg.Type == CoherenceRequestType:GetS) {
                    // NOTE: Since we don't have a TBE in this machine, there
                    // is no need to pass a TBE into trigger. Also, for the
                    // directory there is no cache entry.
                    trigger(Event:GetS, in_msg.addr);
                } else if (in_msg.Type == CoherenceRequestType:GetMOwner) {
                    trigger(Event:GetMOwner, in_msg.addr);
                } else if (in_msg.Type == CoherenceRequestType:GetMNonOwner) { 
                    trigger(Event:GetMNonOwner, in_msg.addr);
                } else if (in_msg.Type == CoherenceRequestType:PutS) {
                    assert(is_valid(entry));
                    // If there is only a single sharer (i.e., the requestor)
                    if (entry.Sharers.count() == 1) {
                        assert(entry.Sharers.isElement(in_msg.Requestor));
                        trigger(Event:PutSLast, in_msg.addr);
                    } else {
                        trigger(Event:PutSNotLast, in_msg.addr);
                    }
                } else if (in_msg.Type == CoherenceRequestType:PutM) {
                    assert(is_valid(entry));
                    if (entry.Owner.isElement(in_msg.Requestor)) {
                        trigger(Event:PutMOwner, in_msg.addr);
                    } else {
                        trigger(Event:PutMNonOwner, in_msg.addr);
                    }
                } else if (in_msg.Type == CoherenceRequestType:PutE) {
                    assert(is_valid(entry));
                    if (entry.Owner.isElement(in_msg.Requestor)) {
                        trigger(Event:PutEOwner, in_msg.addr);
                    } else {
                        trigger(Event:PutENonOwner, in_msg.addr);
                    }
                } else if (in_msg.Type == CoherenceRequestType:PutO) {
                    assert(is_valid(entry));
                    if (entry.Owner.isElement(in_msg.Requestor)) {
                        trigger(Event:PutOOwner, in_msg.addr);
                    } else {
                        trigger(Event:PutONonOwner, in_msg.addr);
                    }
                } else {
                    error("Unexpected message type.");
                }
            }
        }
    }



    /*************************************************************************/
    // Actions

    // Memory actions.

    action(sendMemRead, "r", desc="Send a memory read request") {
        peek(request_in, RequestMsg) {
            // Send request through special memory request queue. At some
            // point the response will be on the memory response queue.
            // Like enqueue, this takes a latency for the request.
            enqueue(memQueue_out, MemoryMsg, toMemLatency) {
                out_msg.addr := address;
                out_msg.Type := MemoryRequestType:MEMORY_READ;
                out_msg.Sender := in_msg.Requestor;
                out_msg.MessageSize := MessageSizeType:Request_Control;
                out_msg.Len := 0;
            }
        }
    }

    action(sendDataToMem, "w", desc="Write data to memory") {
        peek(request_in, RequestMsg) {
            DPRINTF(RubySlicc, "Writing memory for %#x\n", address);
            DPRINTF(RubySlicc, "Writing %s\n", in_msg.DataBlk);
            enqueue(memQueue_out, MemoryMsg, toMemLatency) {
                out_msg.addr := address;
                out_msg.Type := MemoryRequestType:MEMORY_WB;
                out_msg.Sender := in_msg.Requestor;
                out_msg.MessageSize := MessageSizeType:Writeback_Data;
                out_msg.DataBlk := in_msg.DataBlk;
                out_msg.Len := 0;
            }
        }
    }

    action(sendRespDataToMem, "rw", desc="Write data to memory from resp") {
        peek(response_in, ResponseMsg) {
            DPRINTF(RubySlicc, "Writing memory for %#x\n", address);
            DPRINTF(RubySlicc, "Writing %s\n", in_msg.DataBlk);
            enqueue(memQueue_out, MemoryMsg, toMemLatency) {
                out_msg.addr := address;
                out_msg.Type := MemoryRequestType:MEMORY_WB;
                out_msg.Sender := in_msg.Sender;
                out_msg.MessageSize := MessageSizeType:Writeback_Data;
                out_msg.DataBlk := in_msg.DataBlk;
                out_msg.Len := 0;
            }
        }
    }

    // Sharer/owner actions

    action(addReqToSharers, "aS", desc="Add requestor to sharer list") {
        peek(request_in, RequestMsg) {
            getDirectoryEntry(address).Sharers.add(in_msg.Requestor);
        }
    }

    action(setOwner, "sO", desc="Set the owner") {
        peek(request_in, RequestMsg) {
            getDirectoryEntry(address).Owner.add(in_msg.Requestor);
        }
    }

    action(addOwnerToSharers, "oS", desc="Add the owner to sharers") {
        Entry e := getDirectoryEntry(address);
        assert(e.Owner.count() == 1);
        e.Sharers.addNetDest(e.Owner);
    }

    action(removeReqFromSharers, "rS", desc="Remove requestor from sharers") {
        peek(request_in, RequestMsg) {
            getDirectoryEntry(address).Sharers.remove(in_msg.Requestor);
        }
    }

    action(clearSharers, "cS", desc="Clear the sharer list") {
        getDirectoryEntry(address).Sharers.clear();
    }

    action(clearOwner, "cO", desc="Clear the owner") {
        getDirectoryEntry(address).Owner.clear();
    }

    // Invalidates and forwards 
             
    action(sendInvToSharers, "i", desc="Send invalidate to all sharers") {
        peek(request_in, RequestMsg) {
            enqueue(forward_out, RequestMsg, 1) {
                out_msg.addr := address;
                out_msg.Type := CoherenceRequestType:Inv;
                out_msg.Requestor := in_msg.Requestor;
                out_msg.Destination := getDirectoryEntry(address).Sharers;
                out_msg.MessageSize := MessageSizeType:Control;
            }
        }
    }

    action(sendFwdGetS, "fS", desc="Send forward getS to owner") {
        assert(getDirectoryEntry(address).Owner.count() == 1);
        peek(request_in, RequestMsg) {
            enqueue(forward_out, RequestMsg, 1) {
                out_msg.addr := address;
                out_msg.Type := CoherenceRequestType:GetS;
                out_msg.Requestor := in_msg.Requestor;
                out_msg.Destination := getDirectoryEntry(address).Owner;
                out_msg.MessageSize := MessageSizeType:Control;
            }
        }
    }

    action(sendFwdGetM, "fM", desc="Send forward getM to owner") {
        assert(getDirectoryEntry(address).Owner.count() == 1);
        peek(request_in, RequestMsg) {
            enqueue(forward_out, RequestMsg, 1) {
                out_msg.addr := address;
                out_msg.Type := CoherenceRequestType:GetM;
                out_msg.Requestor := in_msg.Requestor;
                out_msg.Destination := getDirectoryEntry(address).Owner;
                out_msg.MessageSize := MessageSizeType:Control;
            }
        }
    }

    // Responses to requests

    action(sendAckCount, "sC", desc="Send AckCount to Requestor") {         //Now adding sending AckCount action for MOESI
        peek(request_in, RequestMsg) {
           enqueue(response_out, ResponseMsg, 1) {
                out_msg.addr := address;
                out_msg.Type := CoherenceResponseType:AckCount;
                out_msg.Sender := machineID;
                out_msg.Destination.add(in_msg.OriginalRequestorMachId);
                out_msg.MessageSize := MessageSizeType:Control; //Is this correct???
                Entry e := getDirectoryEntry(address);                
                out_msg.Acks := e.Sharers.count();
           }
        }
    }
    
    // This also needs to send along the number of sharers!!!!
    action(sendDataToReq, "d", desc="Send data from memory to requestor. ") {
                                    //"May need to send sharer number, too") {
        peek(memQueue_in, MemoryMsg) {
            enqueue(response_out, ResponseMsg, 1) {
                out_msg.addr := address;
                out_msg.Type := CoherenceResponseType:Data;
                out_msg.Sender := machineID;
                out_msg.Destination.add(in_msg.OriginalRequestorMachId);
                out_msg.DataBlk := in_msg.DataBlk;
                out_msg.MessageSize := MessageSizeType:Data;
                Entry e := getDirectoryEntry(address);
                // Only need to include acks if we are the owner.
                if (e.Owner.isElement(in_msg.OriginalRequestorMachId)) {
                    out_msg.Acks := e.Sharers.count();
                } else {
                    out_msg.Acks := 0;
                }
                assert(out_msg.Acks >= 0);
            }
        }
    }
        
    action(sendPutAck, "a", desc="Send the put ack") {
        peek(request_in, RequestMsg) {
            enqueue(forward_out, RequestMsg, 1) {
                out_msg.addr := address;
                out_msg.Type := CoherenceRequestType:PutAck;
                out_msg.Requestor := machineID;
                out_msg.Destination.add(in_msg.Requestor);
                out_msg.MessageSize := MessageSizeType:Control;
            }
        }
    }

    // Queue management

    action(popResponseQueue, "pR", desc="Pop the response queue") {
        response_in.dequeue(clockEdge());
    }

    action(popRequestQueue, "pQ", desc="Pop the request queue") {
        request_in.dequeue(clockEdge());
    }

    action(popMemQueue, "pM", desc="Pop the memory queue") {
        memQueue_in.dequeue(clockEdge());
    }

    // Stalling actions
    action(stall, "z", desc="Stall the incoming request") {
        // Do nothing.
    }


    /*************************************************************************/
    // transitions

    transition(I, GetS, E_m) {
        sendMemRead;
        setOwner;
        popRequestQueue;
    }

    transition(I, GetMNonOwner, M_m) {
        sendMemRead;
        setOwner;
        popRequestQueue;
    }
    
    transition(I, {PutSNotLast, PutSLast, PutMNonOwner, PutENonOwner, PutONonOwner}) {
        sendPutAck;
        popRequestQueue;
    }
    
    transition(S, GetS, S_m) {
        sendMemRead;
        addReqToSharers;
        popRequestQueue;
    }

    transition(S, GetMNonOwner, M_m) {
        sendMemRead;
        removeReqFromSharers;
        sendInvToSharers;
        setOwner;
        popRequestQueue;
    }

    transition({S, S_D, SS_m, S_m}, {PutSNotLast, PutMNonOwner, PutENonOwner, PutONonOwner}) {
        removeReqFromSharers;
        sendPutAck;
        popRequestQueue;
    }
    
    transition(S, PutSLast, I) {
        removeReqFromSharers;
        sendPutAck;
        popRequestQueue;
    }
    
    transition(E, GetS, S_D) {
        sendFwdGetS;
        addReqToSharers;
        addOwnerToSharers;
        clearOwner;
        popRequestQueue;
    }
    
    transition(E, GetMNonOwner, M) {
        sendFwdGetM;
        clearOwner;
        setOwner;
        popRequestQueue;
    }

    transition({E, O, M, E_m, M_m, MI_m}, {PutSNotLast, PutSLast, PutMNonOwner, PutENonOwner, PutONonOwner}) {
        removeReqFromSharers;
        sendPutAck;
        popRequestQueue;
    }
    
    transition({M, E}, PutMOwner, MI_m) {
        sendDataToMem;
        clearOwner;
        sendPutAck;
        popRequestQueue;
    }

    transition(E, PutEOwner, I) {
        sendPutAck;
        clearOwner;
        popRequestQueue;
    }
        
    transition(O, GetS) {
        sendFwdGetS;
        addReqToSharers;
        popRequestQueue;
    }
    
    transition(O, GetMOwner, M) {
       sendAckCount;
       sendInvToSharers;
       clearSharers;
       popRequestQueue;
    }

    transition(O, GetMNonOwner, M) {
       sendFwdGetM;
       sendInvToSharers;
       clearOwner;
       setOwner;
       sendAckCount;
       clearSharers;
       popRequestQueue;
    }

    transition(O, PutMOwner, SS_m) {
       removeReqFromSharers;
       sendDataToMem;
       sendPutAck;
       clearOwner;
       popRequestQueue;
    }
    
    transition(O, PutOOwner, SS_m) {
       sendDataToMem;
       sendPutAck;
       clearOwner;
       popRequestQueue;
    }

    transition(M, GetS, O) {
        sendFwdGetS;
        addReqToSharers;
        popRequestQueue;
    }

    transition(M, GetMNonOwner) {
        sendFwdGetM;
        clearOwner;
        setOwner;
        popRequestQueue;
    }
             
    transition(S_m, MemData, S) {
        sendDataToReq;
        popMemQueue;
    }

    transition(E_m, MemData, E) {
        sendDataToReq;
        popMemQueue;
    }
    
    transition(M_m, MemData, M) {
        sendDataToReq;
        clearSharers; // NOTE: This isn't *required* in some cases.
        popMemQueue;
    }

    transition(S_D, {GetS, GetM}) {
        stall;
    }
    
    transition(S_D, PutSLast) {
        removeReqFromSharers;
        sendPutAck;
        popRequestQueue;
    }

    transition(S_D, Data, SS_m) {
        sendRespDataToMem;
        popResponseQueue;
    }

    // If we get another request for a block that's waiting on memory,
    // stall that request.
    transition({MI_m, SS_m, S_m, E_m, M_m}, {GetS, GetM}) {
        stall;
    } 

    transition(MI_m, MemAck, I) {
        popMemQueue;
    }

    transition(SS_m, MemAck, S) {
        popMemQueue;
    }

  /* 
   transition(M, GetS, S_D) {
        sendFwdGetS;
        addReqToSharers;
        addOwnerToSharers;
        clearOwner;
        popRequestQueue;
    }

   transition(M, GetM) {
        sendFwdGetM;
        clearOwner;
        setOwner;
        popRequestQueue;
    }*/

}
