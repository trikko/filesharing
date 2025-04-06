# FileSharing

A simple sharing service built in D language using [serverino](https://github.com/trikko/serverino). It provides a REST API for uploading and deleting files using AWS S3 compatible storage.

## Features

- Public URL access to uploaded files
- Secure deletion with SHA256 hash verification
- AWS S3 compatible storage backend

## Setup

1. Install `s3cmd` cli. On ubuntu: `apt install s3cmd`
2. Copy `config.d.template` to `config.d` and fill in your AWS credentials and settings
3. Setup your nginx:
```
location / {
   client_max_body_size 1000M; # Max file size

   client_body_temp_path /tmp;
   client_body_in_file_only on;
   client_body_buffer_size 128k;

   proxy_pass_request_body off;
   proxy_set_header Content-Length "0";
   proxy_set_header X-File-Path $request_body_file;
   proxy_set_header Content-Type "text/plain";

   proxy_pass http://localhost:8323; # serverino port


   limit_except POST DELETE {
         deny all;
   }
}
```
4. Upload a file with `curl --data-binary @/path/to/file.mp4 https://your_server/name.mp4` or from stdout `man ls | col -b | curl --data-binary @- https://your_server/man.txt`

## Support the Project

If you find FileSharing useful in your workflow, please consider sponsoring this project. Your support helps maintain the service, implement new features, and ensure its long-term sustainability. Even small contributions make a significant difference in keeping open-source projects like this one alive and thriving. Sponsor us today to help build a better file sharing solution for everyone!


