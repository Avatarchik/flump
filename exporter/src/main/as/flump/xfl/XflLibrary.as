//
// Flump - Copyright 2013 Flump Authors

package flump.xfl {

import aspire.util.Log;
import aspire.util.Map;
import aspire.util.Maps;
import aspire.util.Set;
import aspire.util.Sets;
import aspire.util.XmlUtil;

import deng.fzip.FZip;

import deng.fzip.FZipFile;

import flash.utils.ByteArray;
import flash.utils.Dictionary;

import flump.SwfTexture;
import flump.Util;
import flump.executor.load.LoadedSwf;
import flump.mold.KeyframeMold;
import flump.mold.LayerMold;
import flump.mold.MovieMold;

public class XflLibrary
{
    use namespace xflns;

    public static const FRAME_RATE :String = "frameRate";
    public static const BACKGROUND_COLOR :String = "backgroundColor";

    /**
     * When an exported movie contains an unexported movie, it gets assigned a generated symbol
     * name with this prefix.
     */
    public static const IMPLICIT_PREFIX :String = "~";

    public var swf :LoadedSwf;

    public var frameRate :Number;
    public var backgroundColor :int;

    // The MD5 of the published library SWF
    public var md5 :String;

    public var location :String;

    public const movies :Vector.<MovieMold> = new <MovieMold>[];
    public const textures :Vector.<XflTexture> = new <XflTexture>[];

    public function XflLibrary (location :String) {
        this.location = location;
    }

    public function getItem (id :String, requiredType :Class=null) :* {
        const result :* = _idToItem[id];
        if (result === undefined) throw new Error("Unknown library item '" + id + "'");
        else if (requiredType != null) return requiredType(result);
        else return result;
    }

    public function isExported (movie :MovieMold) :Boolean {
        return _moldToSymbol.containsKey(movie);
    }

    public function get publishedMovies () :Vector.<MovieMold> {
        const result :Vector.<MovieMold> = new <MovieMold>[];
        for each (var movie :MovieMold in _toPublish.toArray().sortOn("id")) result.push(movie);
        return result;
    }

    public function createId (item :Object, libraryName :String, symbol :String) :String {
        if (symbol != null) _moldToSymbol.put(item, symbol);
        const id :String = symbol == null ? IMPLICIT_PREFIX + libraryName : symbol;
        _libraryNameToId.put(libraryName, id);
        _idToItem[id] = item;
        return id;
    }

    public function getErrors (sev :String=null) :Vector.<ParseError> {
        if (sev == null) return _errors;
        const sevOrdinal :int = ParseError.severityToOrdinal(sev);
        return _errors.filter(function (err :ParseError, ..._) :Boolean {
            return err.sevOrdinal >= sevOrdinal;
        });
    }

    public function get valid () :Boolean { return getErrors(ParseError.CRIT).length == 0; }

    public function addTopLevelError (severity :String, message :String, e :Object=null) :void {
        addError(location, severity, message, e);
    }

    public function addError (location :String, severity :String, message :String, e :Object=null) :void {
        _errors.push(new ParseError(location, severity, message, e));
    }

    public function parseFlaFile(flaZip : FZip, _swf : LoadedSwf, _md5 : String) :void {
        swf = _swf;
        md5 = _md5;
        const domFile :FZipFile = flaZip.getFileByName("DOMDocument.xml");
        const docXml :XML = Util.bytesToXML(domFile.content);
        frameRate = XmlUtil.getNumberAttr(docXml, FRAME_RATE, 24);

        const hex :String = XmlUtil.getStringAttr(docXml, BACKGROUND_COLOR, "#ffffff");
        backgroundColor = parseInt(hex.substr(1), 16);

        if (docXml.media != null) {
            for each (var bitmapXML :XML in docXml.media.DOMBitmapItem) {
                if (XmlUtil.getBooleanAttr(bitmapXML, XflSymbol.EXPORT_FOR_ACTIONSCRIPT, false)) {
                    textures.push(new XflTexture(this, bitmapXML));
                }
            }
        }

        const paths :Vector.<String> = new <String>[];
        if (docXml.symbols != null) {
            for each (var symbolXmlPath :XML in docXml.symbols.Include) {
                paths.push("LIBRARY/" + XmlUtil.getStringAttr(symbolXmlPath, "href"));
            }
        }

        for each (var path :String in paths) {
            var symbolFile :FZipFile = flaZip.getFileByName(path);
            parseLibraryFile(symbolFile.content, path);
        }

        var movie :MovieMold = null;
        // Parse all un-exported movies that are referenced by the exported movies.
        for (var ii :int = 0; ii < movies.length; ++ii) {
            movie = movies[ii];
            for each (var symbolName :String in XflMovie.getSymbolNames(movie).toArray()) {
                var xml :XML = _unexportedMovies.remove(symbolName);
                if (xml != null) movies.push(XflMovie.parse(this, xml));
            }
        }
        for each (movie in movies) {
            if (isExported(movie)) {
                prepareForPublishing(movie);
            }
        }
    }

    private function parseLibraryFile(fileData :ByteArray, path :String) :void {
        const xml :XML = Util.bytesToXML(fileData);
        if (!XflSymbol.isSymbolItem(xml)) {
            addTopLevelError(ParseError.DEBUG, "Skipping file since its root element isn't " + XflSymbol.SYMBOL_ITEM);
            return;
        } else if (XmlUtil.getStringAttr(xml, XflSymbol.TYPE, "") == XflSymbol.TYPE_GRAPHIC) {
            trace("Skipping file because symbolType=graphic", path);
            return;
        }

        const isSprite :Boolean = XmlUtil.getBooleanAttr(xml, XflSymbol.IS_SPRITE, false);
        log.debug("Parsing for library", "file", path, "isSprite", isSprite);
        try {
            if (isSprite) {
                // if "export in first frame" is not set, we won't be able to load the texture
                // from the swf.
                // TODO: remove this restriction by loading the entire swf before reading textures?
                if (!XmlUtil.getBooleanAttr(xml, XflSymbol.EXPORT_IN_FIRST_FRAME, true)) {
                    addError(location + ":" + XmlUtil.getStringAttr(xml, XflSymbol.EXPORT_CLASS_NAME), ParseError.CRIT, "\"Export in frame 1\" must be set");
                    return;
                }
                var texture :XflTexture = new XflTexture(this, xml);
                if (texture.isValid(this)) textures.push(texture);
                else addError(location + ":" + texture.symbol, ParseError.CRIT, "Sprite is empty");

            } else {
                // It's a movie. If it's exported, we parse it now.
                // Else, we save it for possible parsing later.
                // (Un-exported movies that are not referenced will not be published.)
                if (XflMovie.isExported(xml)) movies.push(XflMovie.parse(this, xml));
                else _unexportedMovies.put(XflMovie.getName(xml), xml);
            }
        } catch (e :Error) {
            addTopLevelError(ParseError.CRIT, "Unable to parse " + (isSprite ? "sprite" : "movie") + " in " + path, e);
            log.error("Unable to parse " + path, e);
        }
    }

    protected function prepareForPublishing (movie :MovieMold) :void {
        if (!_toPublish.add(movie)) return;

        for each (var layer :LayerMold in movie.layers) {
            for each (var kf :KeyframeMold in layer.keyframes) {
                var swfTexture :SwfTexture = null;
                if (movie.flipbook) {
                    try {
                        swfTexture = SwfTexture.fromFlipbook(this, movie, kf.index)
                    } catch (e :Error) {
                        addTopLevelError(ParseError.CRIT, "Error creating flipbook texture from '" + movie.id + "'");
                        swfTexture = null;
                    }

                } else {
                    if (kf.ref == null) continue;
                    kf.ref = _libraryNameToId.get(kf.ref);
                    var item :Object = _idToItem[kf.ref];
                    if (item == null) {
                        addTopLevelError(ParseError.CRIT, "unrecognized library item '" + kf.ref + "'");
                    } else if (item is MovieMold) {
                        prepareForPublishing(MovieMold(item));
                    } else if (item is XflTexture) {
                        const tex :XflTexture = XflTexture(item);
                        try {
                            swfTexture = SwfTexture.fromTexture(this, tex);
                        } catch (e :Error) {
                            addTopLevelError(ParseError.CRIT, "Error creating texture '" + tex.symbol + "'");
                            swfTexture = null;
                        }
                    }
                }

                if (swfTexture != null) {
                    // Texture symbols have origins. For texture layer keyframes,
                    // we combine the texture's origin with the keyframe's pivot point.
                    kf.pivotX += swfTexture.origin.x;
                    kf.pivotY += swfTexture.origin.y;
                }
            }
        }
    }

    /** Library name to XML for movies in the XFL that are not marked for export */
    protected const _unexportedMovies :Map = Maps.newMapOf(String);

    /** Object to symbol name for all exported textures and movies in the library */
    protected const _moldToSymbol :Map = Maps.newMapOf(Object);

    /** Library name to symbol or generated symbol for all textures and movies in the library */
    protected const _libraryNameToId :Map = Maps.newMapOf(String);

    /** Exported movies or movies used in exported movies. */
    protected const _toPublish :Set = Sets.newSetOf(MovieMold);

    /** Symbol or generated symbol to texture or movie. */
    protected const _idToItem :Dictionary = new Dictionary();

    protected const _errors :Vector.<ParseError> = new <ParseError>[];

    private static const log :Log = Log.getLog(XflLibrary);
}
}
