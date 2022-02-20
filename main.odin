package main

import "notifier";
import da "diag_allocator";
import "core:fmt";
import "core:time";
import "core:path/filepath";

println :: fmt.println;

diag: da.Diag_Allocator;

    

main :: proc ()  {
    using notifier;

    da.diag_allocator_init(&diag, context.allocator);
    context.allocator = da.diag_allocator(&diag);
    defer da.diag_allocator_info(&diag);

    // map_ := make(map[string]int, 0);
    // arr  := make([dynamic]int, 0);

    notifier, err := notifier_create();
    defer notifier_destroy(&notifier);
    err = notifier_add_path(&notifier, "D:/works/odin/odin-notifier/");
    // err = notifier_add_path(&notifier, "D:/works/odin/odin-notifier/folder");
    // err = notifier_add_path(&notifier, "D:/works/odin/odin-notifier/main.odin");

    if err != nil {
        println(err, notifier_last_err());
        return;
    }

    counter := 0;
    for {
        for event in notifier_read_changes(&notifier) {
            switch e in event {
                case File_Changed:
                    println("File changed: ", e.filepath);
                case File_Created:
                    println("File created: ", e.filepath);
                case File_Deleted:
                    println("File deleted: ", e.filepath);
                case File_Renamed:
                    println("File renamed: ", e.old_filepath, "to", e.filepath, );
            }
        }
        counter +=1;        
        time.sleep(time.Second);
        if counter == 10 {
            break;
        }
    }
    
}