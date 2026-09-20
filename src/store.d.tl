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
   record ExportReport
      file: string
      from: integer
      through: integer
      events: integer
   end
   record ImportReport
      events: integer
      reproduced_coordinates: boolean
   end
   record RetainReport
      removed: integer
      streams: integer
   end
   record BlobGcReport
      deleted: integer
      bytes: integer
   end
   append: function(self: store, stream: string, kind: string, meta: any, data: any): Recorded, string
   append_if: function(self: store, stream: string, decision: string, kind: string, meta: any, data: any): Recorded, string
   bind_alias: function(self: store, name: string, card_id: string, note?: string): Recorded, string
   release_alias: function(self: store, name: string, note?: string): Recorded, string
   read_stream: function(self: store, stream: string, kinds?: {string}): {Recorded}, string
   query: function(self: store, sql: string, params: {any}): {any}, string
   catch_up: function(self: store): integer, string
   rebuild: function(self: store): integer, string
   blob_put: function(self: store, bytes: string): Blob, string
   blob_get: function(self: store, hash: string): string, string
   blob_path: function(self: store, hash: string): string
   json_encode: function(self: store, v: any): string, string
   digest: function(self: store, v: any): string
   json_decode: function(self: store, text: string): any, string
   export: function(self: store): ExportReport, string
   import: function(self: store, path: string): ImportReport, string
   retain_streams: function(self: store, streams: {string}): RetainReport, string
   blob_gc: function(self: store): BlobGcReport, string
   root: function(self: store): string
end

return store
