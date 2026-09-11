local record store
   record Recorded
      stream: string
      seq: integer
      position: integer
      epoch_ms: integer
      kind: string
      meta: any
      data: any
   end
   record Blob
      hash: string
      size: integer
   end
   append: function(self: store, stream: string, kind: string, meta: any, data: any): Recorded, string
   append_if: function(self: store, stream: string, decision: string, kind: string, meta: any, data: any): Recorded, string
   read_stream: function(self: store, stream: string, kinds?: {string}): {Recorded}, string
   query: function(self: store, sql: string, params: {any}): {any}, string
   blob_put: function(self: store, bytes: string): Blob, string
   blob_get: function(self: store, hash: string): string, string
   blob_path: function(self: store, hash: string): string
   root: function(self: store): string
end

return store
