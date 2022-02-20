package notifier;

import w "core:sys/windows"

foreign import kernel32 "system:Kernel32.lib"

LPOVERLAPPED_COMPLETION_ROUTINE :: #type proc "stdcall" (
    dwErrorCode :w.DWORD , 
    dwNumberOfBytesTransfered: w.DWORD, 
    lpOverlapped: w.LPOVERLAPPED);

@(default_calling_convention="stdcall")
foreign kernel32 {
    CreateIoCompletionPort :: proc ( 
        FileHandle : w.HANDLE,    
        ExistingCompletionPort : w.HANDLE,
        CompletionKey: w.ULONG_PTR ,
        NumberOfConcurrentThreads: w.DWORD,
    ) -> w.HANDLE ---;

    GetQueuedCompletionStatus :: proc(
        CompletionPort: w.HANDLE ,
        lpNumberOfBytesTransferred: w.LPDWORD ,
        lpCompletionKey: w.PULONG_PTR ,
        lpOverlapped: ^w.LPOVERLAPPED,
        dwMilliseconds : w.DWORD,
    ) -> w.BOOL ---;

    ReadDirectoryChangesW :: proc(
        hDirectory: w.HANDLE,
        lpBuffer: w.LPVOID,
        nBufferLength: w.DWORD,
        bWatchSubtree: w.BOOL,
        dwNotifyFilter: w.DWORD,
        lpBytesReturned: w.LPDWORD,
        lpOverlapped: w.LPOVERLAPPED,
        lpCompletionRoutine: LPOVERLAPPED_COMPLETION_ROUTINE,
      ) -> w.BOOL ---;

}

MAKELANGID :: proc( p: w.WORD, s: w.WORD) -> w.WORD {
    return ((((w.WORD) (s)) << 10) | (w.WORD) (p));
} 


