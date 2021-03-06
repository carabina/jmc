//
//  DatabaseManager.swift
//  minimalTunes
//
//  Created by John Moody on 6/29/16.
//  Copyright © 2016 John Moody. All rights reserved.
//

import Cocoa
import CoreFoundation
import CoreServices
import AVFoundation

func instanceCheck(_ entity: String, name: String) -> NSManagedObject? {
    let managedContext: NSManagedObjectContext = {
        return (NSApplication.shared().delegate
            as? AppDelegate)?.managedObjectContext }()!
    let fetch_req = NSFetchRequest<NSFetchRequestResult>(entityName: entity)
    let predicate = NSPredicate(format: "name == %@", name)
    fetch_req.predicate = predicate
    var results: [NSManagedObject]?
    do {
        results = try managedContext.fetch(fetch_req) as! [NSManagedObject]
    } catch {
        print("err: \(error)")
    }
    if results != nil && results!.count > 0 {
        return results![0]
    }
    else {
        return nil
    }
    
}

func getArt(_ name: String) -> AlbumArtworkCollection? {
    let managedContext: NSManagedObjectContext = {
        return (NSApplication.shared().delegate
            as? AppDelegate)?.managedObjectContext }()!
    let fetch_req = NSFetchRequest<NSFetchRequestResult>(entityName: "AlbumArtworkCollection")
    let predicate = NSPredicate(format: "album.name == %@", name)
    fetch_req.predicate = predicate
    var results: [AlbumArtworkCollection]
    do {
        results = try managedContext.fetch(fetch_req) as! [AlbumArtworkCollection]
        return results[0]
    } catch {
        print("err: \(error)")
        return nil
    }
}

struct FSError {
    var whichError: Int
}

class FileAddToDatabaseError: NSObject {
    var urlString: String
    var error: String
    init(url: String, error: String) {
        self.urlString = url
        self.error = error
    }
}

class DatabaseManager: NSObject {
    
    var organizesMedia: Bool = true
    let fileManager = FileManager.default
    
    lazy var cachedOrders: [CachedOrder]? = {
        let fr = NSFetchRequest<NSFetchRequestResult>(entityName: "CachedOrder")
        do {
            let res = try managedContext.fetch(fr) as! [CachedOrder]
            return res
        } catch {
            print(error)
            return nil
        }
    }()
    
    func getArtworkFromFile(_ urlString: String) -> Data? {
        print("checking for art in file")
        let url = URL(string: urlString)
        let mediaObject = AVAsset(url: url!)
        var art: Data?
        let commonMeta = mediaObject.commonMetadata
        for metadataItem in commonMeta {
            if metadataItem.commonKey == "artwork" {
                print("found art in file")
                art = metadataItem.value as? Data
            }
        }
        if art != nil {
            return art
        }
        else {
            return nil
        }
    }
    
    func searchAlbumDirectoryForArt(_ track: Track) -> URL? {
        let locationURL = URL(string: track.location!)
        let albumDirectoryURL = locationURL!.deletingLastPathComponent()
        do {
            let albumDirectoryContents = try fileManager.contentsOfDirectory(at: albumDirectoryURL, includingPropertiesForKeys: nil, options: FileManager.DirectoryEnumerationOptions.skipsHiddenFiles)
            let potentialImages = albumDirectoryContents.filter({VALID_ARTWORK_TYPE_EXTENSIONS.contains($0.pathExtension.lowercased())})
            if potentialImages.count > 0 {
                return potentialImages[0]
            } else {
                return nil
            }
        } catch {
            print("error looking in album directory for art: \(error)")
            return nil
        }
    }
    
    func addPrimaryArtForTrack(_ track: Track, art: Data) -> Track? {
        print("adding new primary album art")
        let artHash = art.hashValue
        if let currentPrimaryHash = track.album?.primary_art?.image_hash {
            if Int(currentPrimaryHash) == artHash {
                print("artwork collision")
                return nil
            }
        }
        guard let artImage = CGImageSourceCreateWithData(art as CFData, nil) else {return nil}
        guard let artUTI = CGImageSourceGetType(artImage) else {return nil}
        guard let artExtension = getImageExtension(artUTI) else {return nil}
        let newArtwork = NSEntityDescription.insertNewObject(forEntityName: "AlbumArtwork", into: managedContext) as! AlbumArtwork
        newArtwork.image_hash = artHash as NSNumber?
        if track.album?.primary_art != nil {
            let contains: Bool = {
                if track.album?.primary_art?.image_hash == (artHash as NSNumber) {
                    return true
                }
                else {
                    return false
                }
            }()
            guard contains != true else {return track}
            if track.album!.other_art != nil {
                let contains: Bool = {
                    for album in track.album!.other_art!.art! {
                        if (album as! AlbumArtwork).image_hash == (artHash as NSNumber) {
                            return true
                        }
                    }
                    return false
                }()
                guard contains != true else {return track}
                track.album!.other_art!.addArtObject(track.album!.primary_art!)
            }
            else if track.album!.other_art == nil {
                let newArtworkCollection = NSEntityDescription.insertNewObject(forEntityName: "AlbumArtworkCollection", into: managedContext) as! AlbumArtworkCollection
                newArtworkCollection.album = track.album!
                newArtworkCollection.addArtObject(track.album!.primary_art!)
            }
        }
        let artURL = NSURL(string: track.location!)?.deletingLastPathComponent?.appendingPathComponent("\(artHash)").appendingPathExtension(artExtension)
        newArtwork.artwork_location = artURL!.absoluteString
        track.album?.primary_art = newArtwork
        do {
            try art.write(to: artURL!, options: NSData.WritingOptions.atomic)
        } catch {
            print("error writing file: \(error)")
        }
        return track
    }
    
    //OK -- discrete
    func moveFileAfterEdit(_ track: Track) {
        let organizationType = UserDefaults.standard.object(forKey: DEFAULTS_LIBRARY_ORGANIZATION_TYPE_STRING) as! Int
        guard organizationType != NO_ORGANIZATION_TYPE else {return}
        let artistFolderName = track.album?.album_artist?.name != nil ? track.album!.album_artist!.name! : track.artist?.name != nil ? track.artist!.name! : UNKNOWN_ARTIST_STRING
        let albumFolderName = track.album?.name != nil ? track.album!.name! : UNKNOWN_ALBUM_STRING
        let trackName: String
        if track.track_num != nil {
            trackName = "\(track.track_num!) \(track.name!)"
        } else {
            trackName = "\(track.name!)"
        }
        let currentLocationURL = URL(string: track.location!)
        let fileExtension = currentLocationURL?.pathExtension
        let oldAlbumDirectoryURL = currentLocationURL?.deletingLastPathComponent()
        let newArtistDirectoryURL = ((currentLocationURL as NSURL?)?.deletingLastPathComponent as NSURL?)?.deletingLastPathComponent?.deletingLastPathComponent().appendingPathComponent(artistFolderName)
        let newAlbumDirectoryURL = newArtistDirectoryURL?.appendingPathComponent(albumFolderName)
        let newLocationURL = ((currentLocationURL as NSURL?)?.deletingLastPathComponent as NSURL?)?.deletingLastPathComponent?.deletingLastPathComponent().appendingPathComponent(artistFolderName).appendingPathComponent(albumFolderName).appendingPathComponent(trackName).appendingPathExtension(fileExtension!)
        //check if directories already exist
        do {
            try fileManager.createDirectory(at: newAlbumDirectoryURL!, withIntermediateDirectories: true, attributes: nil)
            try fileManager.moveItem(at: currentLocationURL!, to: newLocationURL!)
            track.location = newLocationURL?.absoluteString
        } catch {
            print("error moving file: \(error)")
        }
        do {
            let currentAlbumDirectoryContents = try fileManager.contentsOfDirectory(at: oldAlbumDirectoryURL!, includingPropertiesForKeys: nil, options: FileManager.DirectoryEnumerationOptions.skipsHiddenFiles)
            if currentAlbumDirectoryContents.count == 1 {
                let lastFileURL = currentAlbumDirectoryContents[0]
                let ext = lastFileURL.pathExtension.lowercased()
                if VALID_ARTWORK_TYPE_EXTENSIONS.contains(ext) {
                    let fileName = lastFileURL.lastPathComponent
                    try fileManager.moveItem(at: lastFileURL, to: (newLocationURL?.deletingLastPathComponent().appendingPathComponent(fileName))!)
                }
            }
        } catch {
            print("error checking directory: \(error)")
        }
        print("moved \(currentLocationURL) to \(track.location!)")
    }
    
    func getMDItemFromURL(_ url: URL) -> MDItem? {
        let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL!)
        return item
    }
    
    func addSortValues(_ track: Track) {
        track.sort_name = getSortName(track.name)
        track.sort_artist = getSortName(track.artist?.name)
        track.sort_album = getSortName(track.album?.name)
        track.sort_album_artist = getSortName(track.album?.album_artist?.name)
        track.sort_composer = getSortName(track.composer?.name)
    }
    
    func handleDirectoryEnumerationError(_ url: URL, error: Error) -> Bool {
        print("this is bad! returning true anyway")
        return true
    }
    
    func addTracksFromURLStrings(_ urlStrings: [String]) -> [FileAddToDatabaseError] {
        var errors = [FileAddToDatabaseError]()
        var addedArtists = [String: Artist]()
        var addedAlbums = [String: Album]()
        var addedComposers = [String: Composer]()
        var addedGenres = [String: Genre]()
        var tracks = [Track]()
        var index = 0
        for urlString in urlStrings {
            var addedArtist: Artist?
            var addedAlbum: Album?
            var addedComposer: Composer?
            var addedGenre: Genre?
            var hasArt = false
            guard let url = URL(string: urlString) else {errors.append(FileAddToDatabaseError(url: urlString, error: "Failure constructing NSURL"));continue}
            guard let mediaFileObject = getMDItemFromURL(url) else {errors.append(FileAddToDatabaseError(url: urlString, error: "Failure getting file metadata"));continue}
            let track = NSEntityDescription.insertNewObject(forEntityName: "Track", into: managedContext) as! Track
            let trackView = NSEntityDescription.insertNewObject(forEntityName: "TrackView", into: managedContext) as! TrackView
            trackView.track = track
            var art: Data?
            track.sample_rate = MDItemCopyAttribute(mediaFileObject, "kMDItemAudioSampleRate" as CFString) as? Int as NSNumber?
            track.date_added = Date()
            track.date_modified = MDItemCopyAttribute(mediaFileObject, "kMDItemContentModificationDate" as CFString!) as? Date
            track.file_kind = MDItemCopyAttribute(mediaFileObject, "kMDItemKind" as CFString!) as? String
            let bitRateCheck = MDItemCopyAttribute(mediaFileObject, "kMDItemAudioBitRate" as CFString!) as? Int
            if bitRateCheck != nil {
                track.bit_rate = bitRateCheck!/1000 as NSNumber
            } else {
                managedContext.delete(track.view!)
                managedContext.delete(track)
                continue
            }
            track.id = library?.next_track_id
            library?.next_track_id = Int(library!.next_track_id!) + 1 as NSNumber
            track.status = 0
            track.time = {
                if let time = (MDItemCopyAttribute(mediaFileObject, "kMDItemDurationSeconds" as CFString!) as? Int) {
                    return time * 1000 as NSNumber
                } else {
                    return nil
                }
            }()
            track.size = MDItemCopyAttribute(mediaFileObject, "kMDItemFSSize" as CFString!) as! Int as NSNumber?
            let name = MDItemCopyAttribute(mediaFileObject, "kMDItemTitle" as CFString!) as? String
            if name != nil {
                track.name = name
            } else {
                track.name = url.deletingPathExtension().lastPathComponent
            }
            track.track_num = MDItemCopyAttribute(mediaFileObject, "kMDItemAudioTrackNumber" as CFString!) as? Int as NSNumber?
            if let genreCheck = MDItemCopyAttribute(mediaFileObject, "kMDItemMusicalGenre" as CFString!) as? String {
                if let alreadyAddedGenre = addedGenres[genreCheck] {
                    track.genre = alreadyAddedGenre
                } else {
                    let newGenre = NSEntityDescription.insertNewObject(forEntityName: "Genre", into: managedContext) as! Genre
                    newGenre.name = genreCheck
                    newGenre.id = library?.next_genre_id
                    library?.next_genre_id = Int(library!.next_genre_id!) + 1 as NSNumber
                    track.genre = newGenre
                    addedGenres[genreCheck] = newGenre
                    addedGenre = newGenre
                }
            }
            if let albumCheck = MDItemCopyAttribute(mediaFileObject, "kMDItemAlbum" as CFString!) as? String {
                if let alreadyAddedAlbum = addedAlbums[albumCheck] {
                    track.album = alreadyAddedAlbum
                } else {
                    let newAlbum = NSEntityDescription.insertNewObject(forEntityName: "Album", into: managedContext) as! Album
                    newAlbum.name = albumCheck
                    newAlbum.id = library?.next_album_id
                    library?.next_album_id = Int(library!.next_album_id!) + 1 as NSNumber
                    track.album = newAlbum
                    addedAlbums[albumCheck] = newAlbum
                    addedAlbum = newAlbum
                }
            }
            if let artistCheck = MDItemCopyAttribute(mediaFileObject, "kMDItemAuthors" as CFString!) as? [String] {
                let mainArtistCheck = artistCheck[0]
                if let alreadyAddedArtist = addedArtists[mainArtistCheck] {
                    track.artist = alreadyAddedArtist
                } else {
                    let newArtist = NSEntityDescription.insertNewObject(forEntityName: "Artist", into: managedContext) as! Artist
                    newArtist.name = mainArtistCheck
                    newArtist.id = library?.next_artist_id
                    library?.next_artist_id = Int(library!.next_artist_id!) + 1 as NSNumber
                    track.artist = newArtist
                    addedArtists[mainArtistCheck] = newArtist
                    addedArtist = newArtist
                }
            }
            if let composerCheck = MDItemCopyAttribute(mediaFileObject, "kMDItemComposer" as CFString!) as? String {
                if let alreadyAddedComposer = addedComposers[composerCheck] {
                    track.composer = alreadyAddedComposer
                } else {
                    let newComposer = NSEntityDescription.insertNewObject(forEntityName: "Composer", into: managedContext) as! Composer
                    newComposer.name = composerCheck
                    newComposer.id = library?.next_composer_id
                    library?.next_composer_id = Int(library!.next_composer_id!) + 1 as NSNumber
                    track.composer = newComposer
                    addedComposers[composerCheck] = newComposer
                    addedComposer = newComposer
                }
            }
            //add sort values
            addSortValues(track)
            autoreleasepool {
                /*var otherMetadataForAlbumArt = AVAsset(URL: url).commonMetadata
                otherMetadataForAlbumArt = otherMetadataForAlbumArt.filter({return $0.commonKey == "artwork"})
                if otherMetadataForAlbumArt.count > 0 {
                    art = otherMetadataForAlbumArt[0].value as? NSData
                    if art != nil {
                        hasArt = true
                    }
                }*/
                if moveFileToAppropriateLocationForTrack(track, currentURL: url) != nil {
                    /*if hasArt == true {
                        addPrimaryArtForTrack(track, art: art!)
                    }*/
                    tracks.append(track)
                } else {
                    print("error moving")
                    errors.append(FileAddToDatabaseError(url: urlString, error: "Couldn't move/copy file to album directory"))
                    managedContext.delete(track)
                    managedContext.delete(trackView)
                    if addedArtist != nil {
                        managedContext.delete(addedArtist!)
                    }
                    if addedGenre != nil {
                        managedContext.delete(addedGenre!)
                    }
                    if addedComposer != nil {
                        managedContext.delete(addedComposer!)
                    }
                    if addedAlbum != nil {
                        managedContext.delete(addedAlbum!)
                    }
                }
            }
            print(index)
            addedArtist = nil
            addedAlbum = nil
            addedGenre = nil
            addedComposer = nil
            index += 1
        }
        for order in cachedOrders! {
            reorderForTracks(tracks, cachedOrder: order)
        }
        do {
            try managedContext.save()
        } catch {
            print(error)
        }
        return errors
    }
    
    func moveFileToAppropriateLocationForTrack(_ track: Track, currentURL: URL) -> URL? {
        let fileName = {() -> String in
            switch UserDefaults.standard.bool(forKey: DEFAULTS_RENAMES_FILES_STRING) {
            case true:
                return validateStringForFilename(self.formFilenameForTrack(track))
            default:
                return currentURL.lastPathComponent
            }
        }()
        var albumDirectoryURL: URL?
        var fileURL: URL?
        let orgType = UserDefaults.standard.object(forKey: DEFAULTS_LIBRARY_ORGANIZATION_TYPE_STRING)! as! Int
        if orgType == NO_ORGANIZATION_TYPE {
            track.location = currentURL.deletingLastPathComponent().appendingPathComponent(fileName).absoluteString
            fileURL = currentURL
        } else {
            let libraryPathURL = URL(fileURLWithPath: UserDefaults.standard.object(forKey: DEFAULTS_LIBRARY_PATH_STRING) as! String)
            let albumArtist = validateStringForFilename(track.album?.album_artist?.name != nil ? track.album!.album_artist!.name! : track.artist?.name != nil ? track.artist!.name! : UNKNOWN_ARTIST_STRING)
            let album = validateStringForFilename(track.album?.name != nil ? track.album!.name! : UNKNOWN_ALBUM_STRING)
            albumDirectoryURL = libraryPathURL.appendingPathComponent(albumArtist).appendingPathComponent(album)
            do {
                try fileManager.createDirectory(at: albumDirectoryURL!, withIntermediateDirectories: true, attributes: nil)
            } catch {
                print("error creating album directory: \(error)")
            }
            do {
                fileURL = albumDirectoryURL?.appendingPathComponent(fileName)
                if orgType == MOVE_ORGANIZATION_TYPE {
                    try fileManager.moveItem(at: currentURL, to: fileURL!)
                } else {
                    try fileManager.copyItem(at: currentURL, to: fileURL!)
                }
                track.location = fileURL?.absoluteString
            } catch {
                print("error while moving/copying files: \(error)")
            }
        }
        return fileURL
    }
    
    func moveFileForNetworkTrackToAppropriateLocationWithData(_ track: Track, data: Data) -> Bool {
        let fileName = {() -> String in
            switch UserDefaults.standard.bool(forKey: DEFAULTS_RENAMES_FILES_STRING) {
            case true:
                return self.formFilenameForTrack(track)
            default:
                return URL(string: track.location!)!.lastPathComponent
            }
        }()
        var albumDirectoryURL: URL?
        var fileURL: URL?
        let libraryPathURL = URL(fileURLWithPath: UserDefaults.standard.object(forKey: DEFAULTS_LIBRARY_PATH_STRING) as! String)
        let albumArtist = validateStringForFilename(track.album?.album_artist?.name != nil ? track.album!.album_artist!.name! : track.artist?.name != nil ? track.artist!.name! : UNKNOWN_ARTIST_STRING)
        let album = validateStringForFilename(track.album?.name != nil ? track.album!.name! : UNKNOWN_ALBUM_STRING)
        albumDirectoryURL = libraryPathURL.appendingPathComponent(albumArtist).appendingPathComponent(album)
        do {
            try fileManager.createDirectory(at: albumDirectoryURL!, withIntermediateDirectories: true, attributes: nil)
        } catch {
            print("error creating album directory: \(error)")
            return false
        }
        do {
            fileURL = albumDirectoryURL?.appendingPathComponent(fileName)
            try data.write(to: fileURL!, options: NSData.WritingOptions.atomic)
            track.location = fileURL?.absoluteString
        } catch {
            print("error while moving/copying files: \(error)")
            return false
        }
        return true
    }
    
    func formFilenameForTrack(_ track: Track) -> String {
        let discNumberStringRepresentation: String
        if track.disc_number != nil {
            discNumberStringRepresentation = "\(String(describing: track.disc_number))-"
        } else {
            discNumberStringRepresentation = ""
        }
        let trackNumberStringRepresentation: String
        if track.track_num != nil {
            let trackNumber = Int(track.track_num!)
            if trackNumber < 10 {
                trackNumberStringRepresentation = "0\(trackNumber)"
            } else {
                trackNumberStringRepresentation = String(trackNumber)
            }
        } else {
            trackNumberStringRepresentation = ""
        }
        let trackNameString = track.name != nil ? track.name! : ""
        let trackExtension = URL(string: track.location!)!.pathExtension
        var filenameString = "\(discNumberStringRepresentation)\(trackNumberStringRepresentation) \(trackNameString).\(trackExtension)"
        if filenameString == " " {
            filenameString = NO_FILENAME_STRING
        }
        return filenameString
    }
    
    func createFileForNetworkTrack(_ track: Track, data: Data, trackMetadata: NSDictionary) -> Bool {
        let newTrack = NSEntityDescription.insertNewObject(forEntityName: "Track", into: managedContext) as! Track
        let newTrackView = NSEntityDescription.insertNewObject(forEntityName: "TrackView", into: managedContext) as! TrackView
        newTrackView.track = newTrack
        newTrack.id = library?.next_track_id
        newTrack.status = nil
        library?.next_track_id = Int(library!.next_track_id!) + 1 as NSNumber
        newTrack.status = 1
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        var addedArtist: Artist?
        var addedAlbum: Album?
        var addedComposer: Composer?
        var addedGenre: Genre?
        var addedAlbumArtist: Artist?
        for field in trackMetadata.allKeys as! [String] {
            switch field {
            case "name":
                newTrack.name = trackMetadata["name"] as? String
                newTrackView.name_order = trackMetadata["name_order"] as? Int as NSNumber?
            case "time":
                newTrack.time = trackMetadata["time"] as? NSNumber
            case "artist":
                let artistName = trackMetadata["artist"] as! String
                let artist: Artist = {() -> Artist in
                    let artistCheck = checkIfArtistExists(artistName)
                    if artistCheck == nil {
                        let artist = NSEntityDescription.insertNewObject(forEntityName: "Artist", into: managedContext) as! Artist
                        addedArtist = artist
                        artist.name = artistName
                        artist.id = library?.next_artist_id
                        library?.next_artist_id = Int(library!.next_artist_id!) + 1 as NSNumber
                        return artist
                    } else {
                        artistCheck?.is_network = nil
                        return artistCheck!
                    }
                }()
                newTrack.artist = artist
                newTrackView.artist_order = trackMetadata["artist_order"] as? Int as NSNumber?
            case "album":
                let albumName = trackMetadata["album"] as! String
                let album: Album = {
                    let albumCheck = checkIfAlbumExists(albumName)
                    if albumCheck == nil {
                        let album = NSEntityDescription.insertNewObject(forEntityName: "Album", into: managedContext) as! Album
                        addedAlbum = album
                        album.name = albumName
                        album.id = library?.next_album_id
                        library?.next_album_id = Int(library!.next_album_id!) + 1 as NSNumber
                        return album
                    } else {
                        albumCheck?.is_network = nil
                        return albumCheck!
                    }
                }()
                newTrack.album = album
                newTrackView.album_order = trackMetadata["album_order"] as? Int as NSNumber?
            case "date_added":
                newTrack.date_added = Date()
            case "date_modified":
                newTrack.date_modified = dateFormatter.date(from: trackMetadata["date_modified"] as! String)
            case "date_released":
                newTrack.album?.release_date = dateFormatter.date(from: trackMetadata["date_released"] as! String)
                newTrackView.release_date_order = trackMetadata["release_date_order"] as? Int as NSNumber?
            case "comments":
                newTrack.comments = trackMetadata["comments"] as? String
            case "composer":
                let composerName = trackMetadata["composer"] as! String
                let composer: Composer = {
                    let composerCheck = checkIfComposerExists(composerName)
                    if composerCheck == nil {
                        let composer = NSEntityDescription.insertNewObject(forEntityName: "Composer", into: managedContext) as! Composer
                        addedComposer = composer
                        composer.name = composerName
                        composer.id = library?.next_composer_id
                        library?.next_composer_id = Int(library!.next_composer_id!) + 1 as NSNumber
                        return composer
                    } else {
                        composerCheck?.is_network = nil
                        return composerCheck!
                    }
                }()
                newTrack.composer = composer
            case "disc_number":
                newTrack.disc_number = trackMetadata["disc_number"] as? Int as NSNumber?
            case "genre":
                let genreName = trackMetadata["genre"] as! String
                let genre: Genre = {
                    let genreCheck = checkIfGenreExists(genreName)
                    if genreCheck == nil {
                        let genre = NSEntityDescription.insertNewObject(forEntityName: "Genre", into: managedContext) as! Genre
                        addedGenre = genre
                        genre.name = genreName
                        genre.id = library?.next_genre_id
                        library?.next_genre_id = Int(library!.next_genre_id!) + 1 as NSNumber
                        return genre
                    } else {
                        genreCheck?.is_network = nil
                        return genreCheck!
                    }
                }()
                newTrack.genre = genre
                newTrackView.genre_order = trackMetadata["genre_order"] as? Int as NSNumber?
            case "file_kind":
                newTrack.file_kind = trackMetadata["file_kind"] as? String
                newTrackView.kind_order = trackMetadata["kind_order"] as? Int as NSNumber?
            case "date_last_played":
                newTrack.date_last_played = dateFormatter.date(from: trackMetadata["date_last_played"] as! String)
            case "date_last_skipped":
                newTrack.date_last_skipped = dateFormatter.date(from: trackMetadata["date_last_skipped"] as! String)
            case "movement_name":
                newTrack.movement_name = trackMetadata["movement_name"] as? String
            case "movement_number":
                newTrack.movement_number = trackMetadata["movement_number"] as? Int as NSNumber?
            case "play_count":
                newTrack.play_count = trackMetadata["play_count"] as? Int as NSNumber?
            case "rating":
                newTrack.rating = trackMetadata["rating"] as? Int as NSNumber?
            case "bit_rate":
                newTrack.bit_rate = trackMetadata["bit_rate"] as? Int as NSNumber?
            case "sample_rate":
                newTrack.sample_rate = trackMetadata["sample_rate"] as? Int as NSNumber?
            case "size":
                newTrack.size = trackMetadata["size"] as? Int as NSNumber?
            case "skip_count":
                newTrack.skip_count = trackMetadata["skip_count"] as? Int as NSNumber?
            case "sort_album":
                newTrack.sort_album = trackMetadata["sort_album"] as? String
            case "sort_album_artist":
                newTrack.sort_album_artist = trackMetadata["sort_album_artist"] as? String
                newTrackView.album_artist_order = trackMetadata["album_artist_order"] as? Int as NSNumber?
            case "sort_artist":
                newTrack.sort_artist = trackMetadata["sort_artist"] as? String
            case "sort_composer":
                newTrack.sort_composer = trackMetadata["sort_composer"] as? String
            case "sort_name":
                newTrack.sort_name = trackMetadata["sort_name"] as? String
            case "track_num":
                newTrack.track_num = trackMetadata["track_num"] as? Int as NSNumber?
            case "location":
                newTrack.location = trackMetadata["location"] as? String
            case "album_artist":
                let artistName = trackMetadata["album_artist"] as! String
                let artist: Artist = {
                    let artistCheck = checkIfArtistExists(artistName)
                    if artistCheck == nil {
                        let artist = NSEntityDescription.insertNewObject(forEntityName: "Artist", into: managedContext) as! Artist
                        addedAlbumArtist = artist
                        artist.name = artistName
                        return artist
                    } else {
                        artistCheck?.is_network = nil
                        return artistCheck!
                    }
                }()
                newTrack.album?.album_artist = artist
            default:
                break
            }
        }
        if moveFileForNetworkTrackToAppropriateLocationWithData(newTrack, data: data) == true {
            for order in cachedOrders! {
                reorderForTracks([newTrack], cachedOrder: order)
            }
        } else {
            managedContext.delete(newTrack)
            managedContext.delete(newTrackView)
            if addedArtist != nil {
                managedContext.delete(addedArtist!)
            }
            if addedGenre != nil {
                managedContext.delete(addedGenre!)
            }
            if addedComposer != nil {
                managedContext.delete(addedComposer!)
            }
            if addedAlbum != nil {
                managedContext.delete(addedAlbum!)
            }
            if addedAlbumArtist != nil {
                managedContext.delete(addedAlbumArtist!)
            }
        }
        return true
    }
    
    func trackDoesNotExist(_ track: NSDictionary) -> Bool {
        let trackFetch = NSFetchRequest<NSFetchRequestResult>(entityName: "Track")
        let id = track["id"] as! Int
        let trackPredicate = NSPredicate(format: "id == \(id)")
        trackFetch.predicate = trackPredicate
        do {
            let results = try managedContext.fetch(trackFetch) as! [Track]
            if results.count > 0 {
                if results[0].location == track["location"] as? String {
                    return false
                }
            } else {
                return true
            }
        } catch {
            print(error)
        }
        return true
    }
    
    func saveStreamingNetworkTrack(_ track: Track, data: Data) {
        let fileName = {() -> String in
            switch UserDefaults.standard.bool(forKey: DEFAULTS_RENAMES_FILES_STRING) {
            case true:
                return self.formFilenameForTrack(track)
            default:
                return URL(string: track.location!)!.lastPathComponent
            }
        }()
        var albumDirectoryURL: URL?
        var fileURL: URL?
        let libraryPathURL = URL(fileURLWithPath: UserDefaults.standard.object(forKey: DEFAULTS_LIBRARY_PATH_STRING) as! String)
        let albumArtist = track.album?.album_artist?.name != nil ? track.album!.album_artist!.name! : track.artist?.name != nil ? track.artist!.name! : UNKNOWN_ARTIST_STRING
        let album = track.album?.name != nil ? track.album!.name! : UNKNOWN_ALBUM_STRING
        albumDirectoryURL = libraryPathURL.appendingPathComponent("tmp").appendingPathComponent(albumArtist).appendingPathComponent(album)
        do {
            try fileManager.createDirectory(at: albumDirectoryURL!, withIntermediateDirectories: true, attributes: nil)
        } catch {
            print("error creating album directory: \(error)")
        }
        do {
            fileURL = albumDirectoryURL?.appendingPathComponent(fileName)
            try data.write(to: fileURL!, options: NSData.WritingOptions.atomic)
            track.location = fileURL?.absoluteString
        } catch {
            print("error while moving/copying files: \(error)")
        }
    }

    func addTracksForPlaylistData(_ playlistDictionary: NSDictionary, item: SourceListItem) {
        let library = {() -> Library? in
            let fetchReq = NSFetchRequest<NSFetchRequestResult>(entityName: "Library")
            let predicate = NSPredicate(format: "is_network == nil OR is_network == false")
            fetchReq.predicate = predicate
            do {
                let result = try managedContext.fetch(fetchReq)[0] as! Library
                return result
            } catch {
                return nil
            }
        }()
        //get tracks
        let tracks = playlistDictionary["playlist"] as! [NSDictionary]
        let addedArtists = NSMutableDictionary()
        let addedAlbums = NSMutableDictionary()
        let addedComposers = NSMutableDictionary()
        let addedGenres = NSMutableDictionary()
        let addedTracks = NSMutableDictionary()
        var addedTrackViews = [TrackView]()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        for track in tracks {
            guard trackDoesNotExist(track) else {continue}
            let newTrack = NSEntityDescription.insertNewObject(forEntityName: "Track", into: managedContext) as! Track
            let newTrackView = NSEntityDescription.insertNewObject(forEntityName: "TrackView", into: managedContext) as! TrackView
            newTrackView.is_network = true
            newTrackView.track = newTrack
            newTrack.is_network = true
            newTrack.is_playing = false
            for field in track.allKeys as! [String] {
                let trackArtist: Artist
                switch field {
                case "id":
                    let id = track["id"] as! Int
                    newTrack.id = track["id"] as? Int as NSNumber?
                    addedTracks[id] = newTrack
                case "is_enabled":
                    newTrack.status = track["is_enabled"] as? Bool as NSNumber?
                case "name":
                    newTrack.name = track["name"] as? String
                    newTrackView.name_order = track["name_order"] as? Int as NSNumber?
                case "time":
                    newTrack.time = track["time"] as? NSNumber
                case "artist":
                    let artistName = track["artist"] as! String
                    let artist: Artist = {
                        if addedArtists[artistName] != nil {
                            return addedArtists[artistName] as! Artist
                        } else {
                            let artistCheck = checkIfArtistExists(artistName)
                            if artistCheck == nil {
                                let artist = NSEntityDescription.insertNewObject(forEntityName: "Artist", into: managedContext) as! Artist
                                artist.name = artistName
                                artist.id = library?.next_artist_id
                                library?.next_artist_id = Int(library!.next_artist_id!) + 1 as NSNumber
                                artist.is_network = true
                                addedArtists[artistName] = artist
                                return artist
                            } else {
                                return artistCheck!
                            }
                        }
                    }()
                    newTrack.artist = artist
                    newTrackView.artist_order = track["artist_order"] as? Int as NSNumber?
                    trackArtist = artist
                case "album":
                    let albumName = track["album"] as! String
                    let album: Album = {
                        if addedAlbums[albumName] != nil {
                            return addedAlbums[albumName] as! Album
                        } else {
                            let albumCheck = checkIfAlbumExists(albumName)
                            if albumCheck == nil {
                                let album = NSEntityDescription.insertNewObject(forEntityName: "Album", into: managedContext) as! Album
                                album.name = albumName
                                album.id = library?.next_album_id
                                library?.next_album_id = Int(library!.next_album_id!) + 1 as NSNumber
                                album.is_network = true
                                addedAlbums[albumName] = album
                                return album
                            } else {
                                return albumCheck!
                            }
                        }
                    }()
                    newTrack.album = album
                    newTrackView.album_order = track["album_order"] as? Int as NSNumber?
                case "date_added":
                    newTrack.date_added = dateFormatter.date(from: track["date_added"] as! String)
                    newTrackView.date_added_order = track["date_added_order"] as? Int as NSNumber?
                case "date_modified":
                    newTrack.date_modified = dateFormatter.date(from: track["date_modified"] as! String)
                case "date_released":
                    newTrack.album?.release_date = dateFormatter.date(from: track["date_released"] as! String)
                    newTrackView.release_date_order = track["release_date_order"] as? Int as NSNumber?
                case "comments":
                    newTrack.comments = track["comments"] as? String
                case "composer":
                    let composerName = track["composer"] as! String
                    let composer: Composer = {
                        if addedComposers[composerName] != nil {
                            return addedComposers[composerName] as! Composer
                        } else {
                            let composerCheck = checkIfComposerExists(composerName)
                            if composerCheck == nil {
                                let composer = NSEntityDescription.insertNewObject(forEntityName: "Composer", into: managedContext) as! Composer
                                composer.name = composerName
                                composer.id = library?.next_composer_id
                                library?.next_composer_id = Int(library!.next_composer_id!) + 1 as NSNumber
                                composer.is_network = true
                                addedComposers[composerName] = composer
                                return composer
                            } else {
                                return composerCheck!
                            }
                        }
                    }()
                    newTrack.composer = composer
                case "disc_number":
                    newTrack.disc_number = track["disc_number"] as? Int as NSNumber?
                case "equalizer_preset":
                    newTrack.equalizer_preset = track["equalizer_preset"] as? String
                case "genre":
                    let genreName = track["genre"] as! String
                    let genre: Genre = {
                        if addedComposers[genreName] != nil {
                            return addedGenres[genreName] as! Genre
                        } else {
                            let genreCheck = checkIfGenreExists(genreName)
                            if genreCheck == nil {
                                let genre = NSEntityDescription.insertNewObject(forEntityName: "Genre", into: managedContext) as! Genre
                                genre.name = genreName
                                genre.id = library?.next_genre_id
                                library?.next_genre_id = Int(library!.next_genre_id!) + 1 as NSNumber
                                genre.is_network = true
                                addedGenres[genreName] = genre
                                return genre
                            } else {
                                return genreCheck!
                            }
                        }
                    }()
                    newTrack.genre = genre
                    newTrackView.genre_order = track["genre_order"] as? Int as NSNumber?
                case "file_kind":
                    newTrack.file_kind = track["file_kind"] as? String
                    newTrackView.kind_order = track["kind_order"] as? Int as NSNumber?
                case "date_last_played":
                    newTrack.date_last_played = dateFormatter.date(from: track["date_last_played"] as! String)
                case "date_last_skipped":
                    newTrack.date_last_skipped = dateFormatter.date(from: track["date_last_skipped"] as! String)
                case "movement_name":
                    newTrack.movement_name = track["movement_name"] as? String
                case "movement_number":
                    newTrack.movement_number = track["movement_number"] as? Int as NSNumber?
                case "play_count":
                    newTrack.play_count = track["play_count"] as? Int as NSNumber?
                case "rating":
                    newTrack.rating = track["rating"] as? Int as NSNumber?
                case "bit_rate":
                    newTrack.bit_rate = track["bit_rate"] as? Int as NSNumber?
                case "sample_rate":
                    newTrack.sample_rate = track["sample_rate"] as? Int as NSNumber?
                case "size":
                    newTrack.size = track["size"] as? Int as NSNumber?
                case "skip_count":
                    newTrack.skip_count = track["skip_count"] as? Int as NSNumber?
                case "sort_album":
                    newTrack.sort_album = track["sort_album"] as? String
                case "sort_album_artist":
                    newTrack.sort_album_artist = track["sort_album_artist"] as? String
                    newTrackView.album_artist_order = track["album_artist_order"] as? Int as NSNumber?
                case "sort_artist":
                    newTrack.sort_artist = track["sort_artist"] as? String
                case "sort_composer":
                    newTrack.sort_composer = track["sort_composer"] as? String
                case "sort_name":
                    newTrack.sort_name = track["sort_name"] as? String
                case "track_num":
                    newTrack.track_num = track["track_num"] as? Int as NSNumber?
                case "location":
                    newTrack.location = track["location"] as? String
                case "album_artist":
                    let artistName = track["album_artist"] as! String
                    let artist: Artist = {
                        if addedArtists[artistName] != nil {
                            return addedArtists[artistName] as! Artist
                        } else {
                            let artistCheck = checkIfArtistExists(artistName)
                            if artistCheck == nil {
                                let artist = NSEntityDescription.insertNewObject(forEntityName: "Artist", into: managedContext) as! Artist
                                artist.name = artistName
                                artist.is_network = true
                                addedArtists[artistName] = artist
                                return artist
                            } else {
                                return artistCheck!
                            }
                        }
                    }()
                    newTrack.album?.album_artist = artist
                default:
                    break
                }
            }
            addedTrackViews.append(newTrackView)
        }
        let track_id_list = addedTrackViews.map({return Int($0.track!.id!)})
        item.playlist?.track_id_list = track_id_list as NSObject?
    }
}
