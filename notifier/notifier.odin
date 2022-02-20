package notifier;

import w "core:sys/windows"
import "core:sys/win32"
import "core:time"
import "core:mem"
import "core:fmt"
import "core:path/filepath"

NOTIFY_DEFAULT_FLAGS : w.DWORD :
    win32.FILE_NOTIFY_CHANGE_LAST_WRITE |
    win32.FILE_NOTIFY_CHANGE_FILE_NAME |
    win32.FILE_NOTIFY_CHANGE_DIR_NAME ;

NOTIFIER_SAME_EVENT_DELAY :: 2000; // in milliseconds

Notifier_Error :: enum {
    None,
    Failed_Create_IOCP,
    Failed_Read_Path_Attributes,
    Failed_Read_Path,
    Failed_Read_Changes,
}

Notifier_Entry_Type :: enum {
    File,
    Directory,
}

Notifier_Watch_Entry :: struct {
    overlapped: w.OVERLAPPED,
    handle: w.HANDLE,
    iocp: w.HANDLE,
    path: string,
    kind: Notifier_Entry_Type,
    files: map[string]time.Tick,
}

Notifier :: struct {
    allocator: mem.Allocator,
    iocp: w.HANDLE,
    entries : [dynamic]^Notifier_Watch_Entry,
    buffer: [4096]u8,
}

File_Changed :: struct {
    filepath: string,
}

File_Renamed :: struct {
    old_filepath: string,
    filepath: string,
}

File_Created :: struct {
    filepath: string,
}

File_Deleted :: struct {
    filepath: string,
}

Notifier_Events :: union {
    File_Changed,
    File_Renamed,
    File_Created,
    File_Deleted,
}



// MAIN API

notifier_create :: proc ( allocator:= context.allocator ) -> (Notifier, Notifier_Error) {

    iocp := CreateIoCompletionPort(w.INVALID_HANDLE, nil, 0, 1);

    notifier : Notifier = ---;

    if iocp == nil {
        return notifier, .Failed_Create_IOCP;
    }

    notifier.allocator     = allocator;
    notifier.iocp          = iocp;
    notifier.entries       = make( [dynamic]^Notifier_Watch_Entry, 0, allocator);

    return notifier, nil;
}

notifier_destroy :: proc( self: ^Notifier ) {

    for entry in self.entries {
        w.CloseHandle(entry.iocp);
        w.CloseHandle(entry.handle);
        delete( entry.files );
        delete( entry.path, self.allocator );
        free( entry, self.allocator );
    }

    w.CloseHandle(self.iocp);
    delete( self.entries );

}

notifier_add_path :: proc ( self: ^Notifier, path: string ) -> Notifier_Error {
    path , _        := filepath.abs( path );
    dir             := filepath.dir( path , context.temp_allocator);
    kind            := notifier_get_file_kind( path ) or_return;
    // dir, kind       := notifier_get_dir_from_path( path ) or_return;
    file_handle     := notifier_handle_from_dir( dir ) or_return;
    iocp            := CreateIoCompletionPort(file_handle, self.iocp, 0, 1);
    if iocp == nil {
        return .Failed_Create_IOCP;
    }


    entry :       = new( Notifier_Watch_Entry, self.allocator );
    entry.handle  = file_handle;
    entry.iocp    = iocp;
    entry.path    = path;
    entry.kind    = kind;
    entry.files   = make(map[string]time.Tick, 0, self.allocator);

    append(&self.entries, entry);

    notifier_prepare_handle_to_watch( self, entry ) or_return;


    return nil;
}

notifier_read_changes :: proc (self: ^Notifier) -> []Notifier_Events {
    events := make([dynamic]Notifier_Events, 0, context.temp_allocator);

    old_filepath := "";
    
    bytes_transfered : u32 = --- ;
    completion_key   : uint = --- ;
    overlapped       : ^w.OVERLAPPED;

    _ = GetQueuedCompletionStatus(self.iocp, &bytes_transfered, &completion_key, &overlapped, 0);

    if overlapped != nil {

        notification      := (^win32.File_Notify_Information)(&self.buffer[0]);
        entry             := (^Notifier_Watch_Entry)(overlapped);

        for{

            filename_w := win32.Wstring(&notification.file_name[0]);
            filename   := w.wstring_to_utf8( filename_w, int(notification.file_name_length) / 2, context.temp_allocator );

            dir                 := filepath.dir(entry.path, context.temp_allocator);
            complete_filepath   := filepath.join( elems = {dir, filename}, allocator = context.temp_allocator );

            if entry.kind == .File {
                // go to next notification and skip this because is not the
                // file that i want to watch
                if entry.path != complete_filepath {
                    if notification.next_entry_offset == 0 do break;
                    notification = (^win32.File_Notify_Information)( uintptr(notification) + uintptr(notification.next_entry_offset) );
                    continue;
                }
            }

            file_entry, found := &entry.files[ complete_filepath ];
            current_time := time.tick_now();

            if complete_filepath in entry.files {
                
                diff := time.tick_diff(file_entry^, current_time );

                if diff < time.Millisecond * NOTIFIER_SAME_EVENT_DELAY {

                    if notification.next_entry_offset == 0 do break;
                    notification = (^win32.File_Notify_Information)( uintptr(notification) + uintptr(notification.next_entry_offset) );
                    continue;

                }

            }

            switch notification.action {
                case win32.FILE_ACTION_ADDED:
                    append(&events, File_Created{ complete_filepath });
                case win32.FILE_ACTION_REMOVED:
                    append(&events, File_Deleted{ complete_filepath });
                case win32.FILE_ACTION_MODIFIED:
                    append(&events, File_Changed{ complete_filepath });
                case win32.FILE_ACTION_RENAMED_OLD_NAME:
                    old_filepath = complete_filepath;
                case win32.FILE_ACTION_RENAMED_NEW_NAME:
                    append(&events, File_Renamed{ old_filepath, complete_filepath });
            }

            entry.files[ complete_filepath ] = time.tick_now();

            if notification.next_entry_offset == 0 do break;
            notification = (^win32.File_Notify_Information)( uintptr(notification) + uintptr(notification.next_entry_offset) );
        }

        notifier_prepare_handle_to_watch(self, entry );

    }

    return events[:];

}

// UTIL

//temporary string
notifier_last_err :: proc () -> string {

    buffer: [512]u16;
    err_code := w.GetLastError();
    
    if err_code != 0 {
        w.FormatMessageW(
            w.FORMAT_MESSAGE_FROM_SYSTEM | w.FORMAT_MESSAGE_IGNORE_INSERTS,
            nil, 
            err_code, 
            0, 
            &buffer[0], 
            size_of(type_of(buffer)) ,
            nil,
        );

        return fmt.tprintf(
            "CODE: %d : %s", 
            err_code,
            w.wstring_to_utf8(&buffer[0], 512, context.temp_allocator),
        );
    } else {
        return "";
    }
}


// PRIVATE

@(private)
notifier_get_file_kind :: proc ( path: string ) -> (Notifier_Entry_Type, Notifier_Error) {
    pathw := w.utf8_to_wstring(path, context.temp_allocator);
    attr := w.GetFileAttributesW( pathw );
    if i32(attr) == w.INVALID_FILE_ATTRIBUTES {
        return nil, .Failed_Read_Path_Attributes;
    } 

    if attr & w.FILE_ATTRIBUTE_DIRECTORY != 0 {
        return .Directory, nil;
    } else {
        return .File, nil;;
    }
}

@(private)
notifier_get_dir_from_path :: proc ( path: string ) -> (string, Notifier_Entry_Type, Notifier_Error) {

    dir_name    := "";
    pathw := w.utf8_to_wstring(path, context.temp_allocator);
    attr := w.GetFileAttributesW( pathw );
    if i32(attr) == w.INVALID_FILE_ATTRIBUTES {
        return "", nil, .Failed_Read_Path_Attributes;
    } 

    kind : Notifier_Entry_Type = ---;

    if attr & w.FILE_ATTRIBUTE_DIRECTORY != 0 {
        dir_name = path;
        kind = .Directory;
    } else {
        dir_name = filepath.clean( 
            filepath.dir(path, context.temp_allocator ), 
            context.temp_allocator,
        );
        kind = .File;
    }
    return dir_name, kind, nil;
}

@(private)
notifier_handle_from_dir :: proc ( dir: string ) -> (w.HANDLE, Notifier_Error) {

    // Does CreateFileW need file path to be persistent?
    file_handle := w.CreateFileW( 
        w.utf8_to_wstring(dir, context.temp_allocator),
        win32.FILE_LIST_DIRECTORY,
        win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE | win32.FILE_SHARE_DELETE,
        nil, win32.OPEN_EXISTING, 
        win32.FILE_FLAG_BACKUP_SEMANTICS | win32.FILE_FLAG_OVERLAPPED, nil );
    
    if file_handle == nil {
        return w.INVALID_HANDLE, .Failed_Read_Path;
    }

    file_info : w.BY_HANDLE_FILE_INFORMATION = ---;
    
    if w.GetFileInformationByHandle(file_handle, &file_info) == w.BOOL(false) {
        
        w.CloseHandle(file_handle);
        return w.INVALID_HANDLE , .Failed_Read_Path;
    }

    return file_handle, nil;
    
}

@(private)
notifier_prepare_handle_to_watch :: proc ( self: ^Notifier, notifier_entry:^Notifier_Watch_Entry ) -> Notifier_Error {

    recursive : w.BOOL = true;
    if notifier_entry.kind == .File {
        recursive = false;
    }

    result := ReadDirectoryChangesW(
            notifier_entry.handle, 
            &self.buffer[0],
            u32( size_of(type_of(self.buffer)) ), 
            recursive, //recursive
            NOTIFY_DEFAULT_FLAGS, 
            nil, 
            &notifier_entry.overlapped, 
            nil,
        );

    if result == false {
        return .Failed_Read_Changes
    }

    return nil;

}


