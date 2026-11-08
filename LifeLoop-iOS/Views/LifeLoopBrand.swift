import SwiftUI

enum LifeLoopBrand {
    static let tabIcon: UIImage = {
        guard let image = UIImage(named: "LifeLoopLogo") else { return UIImage() }
        let size = CGSize(width: 27, height: 27)
        return UIGraphicsImageRenderer(size: size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }.withRenderingMode(.alwaysOriginal)
    }()
}
