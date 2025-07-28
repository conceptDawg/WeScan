//
//  VisionRectangleDetector.swift
//  WeScan
//
//  Created by Julian Schiavo on 28/7/2018.
//  Copyright © 2018 WeTransfer. All rights reserved.
//

import CoreImage
import Foundation
import Vision

/// Class used to detect rectangles from an image on iOS 11.0+.
@available(iOS 11.0, *)
enum VisionRectangleDetector {
    
    /// Detects rectangles from the given CVPixelBuffer on iOS 11.0+.
    ///
    /// - Parameters:
    ///   - pixelBuffer: The pixel buffer to detect rectangles on.
    ///   - minimumAspectRatio: Minimum aspect ratio for detected rectangles (default: 0.3)
    ///   - maximumAspectRatio: Maximum aspect ratio for detected rectangles (default: 1.0)
    ///   - minimumConfidence: Minimum confidence for rectangle detection (default: 0.8)
    ///   - maximumObservations: Maximum number of rectangles to detect (default: 1)
    ///   - minimumSize: Minimum size as fraction of image size (default: 0.2)
    ///   - quadratureTolerance: How much the shape can deviate from perfect quadrilateral (default: 30.0)
    ///   - completion: The completion block that gets called with the detected rectangle.
    static func rectangle(forPixelBuffer pixelBuffer: CVPixelBuffer,
                         minimumAspectRatio: Float = 0.3,
                         maximumAspectRatio: Float = 1.0,
                         minimumConfidence: Float = 0.8,
                         maximumObservations: Int = 1,
                         minimumSize: Float = 0.2,
                         quadratureTolerance: Float = 30.0,
                         completion: @escaping ((Quadrilateral?) -> Void)) {
        
        let imageRequestHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        
        let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        
        completeImageRequest(for: imageRequestHandler,
                           width: width,
                           height: height,
                           minimumAspectRatio: minimumAspectRatio,
                           maximumAspectRatio: maximumAspectRatio,
                           minimumConfidence: minimumConfidence,
                           maximumObservations: maximumObservations,
                           minimumSize: minimumSize,
                           quadratureTolerance: quadratureTolerance,
                           completion: completion)
    }
    
    /// Detects rectangles from the given image on iOS 11.0+.
    ///
    /// - Parameters:
    ///   - ciImage: The image to detect rectangles on.
    ///   - orientation: The orientation to use when detecting rectangles.
    ///   - minimumAspectRatio: Minimum aspect ratio for detected rectangles (default: 0.3)
    ///   - maximumAspectRatio: Maximum aspect ratio for detected rectangles (default: 1.0)
    ///   - minimumConfidence: Minimum confidence for rectangle detection (default: 0.8)
    ///   - maximumObservations: Maximum number of rectangles to detect (default: 1)
    ///   - minimumSize: Minimum size as fraction of image size (default: 0.2)
    ///   - quadratureTolerance: How much the shape can deviate from perfect quadrilateral (default: 30.0)
    ///   - completion: The completion block that gets called with the detected rectangle.
    static func rectangle(forImage ciImage: CIImage, 
                         orientation: CGImagePropertyOrientation,
                         minimumAspectRatio: Float = 0.3,
                         maximumAspectRatio: Float = 1.0,
                         minimumConfidence: Float = 0.8,
                         maximumObservations: Int = 1,
                         minimumSize: Float = 0.2,
                         quadratureTolerance: Float = 30.0,
                         completion: @escaping ((Quadrilateral?) -> Void)) {
        
        let imageRequestHandler = VNImageRequestHandler(ciImage: ciImage, orientation: orientation, options: [:])
        
        completeImageRequest(for: imageRequestHandler,
                           width: ciImage.extent.width,
                           height: ciImage.extent.height,
                           minimumAspectRatio: minimumAspectRatio,
                           maximumAspectRatio: maximumAspectRatio,
                           minimumConfidence: minimumConfidence,
                           maximumObservations: maximumObservations,
                           minimumSize: minimumSize,
                           quadratureTolerance: quadratureTolerance,
                           completion: completion)
    }
    
    private static func completeImageRequest(for imageRequestHandler: VNImageRequestHandler,
                                           width: CGFloat,
                                           height: CGFloat,
                                           minimumAspectRatio: Float,
                                           maximumAspectRatio: Float,
                                           minimumConfidence: Float,
                                           maximumObservations: Int,
                                           minimumSize: Float,
                                           quadratureTolerance: Float,
                                           completion: @escaping ((Quadrilateral?) -> Void)) {
        
                 let rectDetectRequest = VNDetectRectanglesRequest { (request, error) in
             guard error == nil, let results = request.results as? [VNRectangleObservation], !results.isEmpty else {
                 completion(nil)
                 return
             }
             
             let quads: [Quadrilateral] = results.map(Quadrilateral.init)
             
             guard let biggest = quads.biggest() else {
                 completion(nil)
                 return
             }
             
             let transform = CGAffineTransform.identity.scaledBy(x: width, y: height)
             completion(biggest.applying(transform))
         }
        
        // Use the configurable parameters instead of hardcoded values
        rectDetectRequest.minimumConfidence = minimumConfidence
        rectDetectRequest.maximumObservations = maximumObservations
        rectDetectRequest.minimumAspectRatio = minimumAspectRatio
        rectDetectRequest.maximumAspectRatio = maximumAspectRatio
        rectDetectRequest.minimumSize = minimumSize
        rectDetectRequest.quadratureTolerance = VNDegrees(quadratureTolerance)
        
        do {
            try imageRequestHandler.perform([rectDetectRequest])
        } catch {
            completion(nil)
            return
        }
    }
}
