//
// Flump - Copyright 2012 Three Rings Design

package flump {

import flash.display.Loader;

public class ImageLoader extends BaseLoader
{
    override protected function handleSuccess (onSuccess :Function, loader :Loader) :void {
        onSuccess(new Image(loader));
    }
}
}
